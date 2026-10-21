// SPDX-License-Identifier: CC0-1.0
import AVFoundation
import UIKit

/// Music mode's player, audio-only through the same source chain as the
/// watch screen, with no video layer at all.
///
/// What plays next: the top of the user's queue when it has anything, else
/// the next track of the album or playlist being played (the context).
/// Played tracks leave both lists — a history behind them only serves the
/// previous button. All of it is saved, so the next launch picks up the
/// same album, playlist or radio, not just the last track.
///
/// Playback does not stop at the end of a context: YouTube Music's
/// recommendations take over (see `topUpRadioIfNeeded`). Offline, only
/// downloaded tracks play, and the end of those is the end.
///
/// The next track is resolved and handed to the queue player before the
/// current one ends, so it is already buffering when a dead zone hits and
/// the switch is gapless.
final class MusicPlayer: NSObject {
    enum RepeatMode: String, Codable {
        case off, all, one
    }

    /// Where more tracks come from once `upcoming` runs low.
    private struct Radio: Codable {
        /// The watch queue's next slice, while it has one.
        var continuation: String?
        /// Recommendations from what was played lately (see `mixSeeds`).
        var isMix: Bool
        /// The web account's recommendations rather than signed-out ones.
        var signedIn: Bool
        /// The finished playlist whose own automix to ask YouTube Music
        /// for (the "YouTube Music's recommendations" setting).
        var playlistId: String?
        /// An endless start (artist shuffle, song radio): new tracks join
        /// its context. What follows a finished album or playlist does not —
        /// those are not its tracks, for the artwork or for repeat-all.
        var joinsContext: Bool
    }

    /// A track heard, for seeding the mix.
    private struct RecentPlay: Codable {
        let video: Video
        /// Brought in by a mix rather than chosen.
        let fromMix: Bool
    }

    static let shared = MusicPlayer()
    /// Track, play state, queue or mode changed.
    static let didChangeNotification = Notification.Name("MusicPlayerDidChange")

    /// The player of the song playing. Crossfading swaps it with `spare`,
    /// which then fades the song before out; everything follows `player`.
    private(set) var player = AVQueuePlayer()
    private var spare = AVQueuePlayer()
    private(set) var current: Video?
    /// Added by the user ("Play next", "Add to queue"); plays first.
    private(set) var queue: [Video] = []
    /// The rest of the album or playlist, in play order.
    private(set) var upcoming: [Video] = []
    /// What `upcoming` comes from, for the Up next header.
    private(set) var contextTitle: String?
    private(set) var isShuffled = false
    private(set) var repeatMode: RepeatMode = .off
    /// Resolving the stream for the current track.
    private(set) var isLoading = false
    /// Square album art for the whole context; playlists use each track's own.
    private(set) var collectionArtworkURL: String?

    /// The whole context in its own order: repeat-all starts it over, and
    /// shuffle off puts `upcoming` back in this order.
    private var context: [Video] = []
    /// The album or playlist's title while a mix stands in for it, for
    /// repeat-all turned on afterwards (`dropEndless`).
    private var titleBeforeEndless: String?
    private var history: [Video] = []
    private var facade = PlaybackFacade()
    private var token = CancellationToken()
    private var resourceLoader: AVAssetResourceLoaderDelegate?
    private var timeObserver: Any?
    /// The player `timeObserver` belongs to: removing it from another throws.
    private weak var observed: AVQueuePlayer?
    private var rateObservation: NSKeyValueObservation?
    /// Tracks in a row that would not play; past a few, stop instead of
    /// skipping through the whole queue.
    private var consecutiveFailures = 0
    /// Where the next load starts: 0 for a track picked anew, the saved
    /// position when resuming the last session.
    private var pendingStart: TimeInterval = 0
    private var lastSaved = Date.distantPast
    private let prefetcher = Prefetcher()
    /// Endless playback: an artist's "Play" from the start, any context
    /// once it has run out (as a mix of what was played lately).
    private var radio: Radio?
    private var isFetchingRadio = false
    /// Bumped whenever `radio` starts over, so a late answer for an
    /// earlier context is dropped.
    private var radioGeneration = 0
    /// Everything ran out while more was being fetched: play on once it
    /// arrives.
    private var waitingForMore = false
    /// Tracks the mix brought into `upcoming`, so their plays are told
    /// apart from chosen ones.
    private var mixIds: Set<String> = []
    /// The album or playlist being played, for YouTube Music's own
    /// recommendations after it.
    private var collectionId: String?
    /// The latest plays, oldest first: up to `mixSeedCount` chosen and
    /// `mixSeedShare` from mixes. Kept across contexts and launches.
    private var recent: [RecentPlay] = {
        guard let data = UserDefaults.standard.data(forKey: MusicPlayer.recentKey),
              let stored = try? JSONDecoder().decode([RecentPlay].self, from: data)
        else {
            return []
        }
        return stored
    }()
    private static let recentKey = "musicPlayer_recentPlays"
    /// What a temporary playlist holds: YouTube keeps the first 50 ids.
    private static let mixSeedCount = 50
    /// At most this many seeds from mixes, so each mix stays close to what
    /// was chosen instead of drifting along its own picks.
    private static let mixSeedShare = 15
    private let sessionWriter = DispatchQueue(label: "MusicPlayer.session", qos: .utility)

    var isActive: Bool {
        current != nil
    }

    /// Nothing audible while the network is out (`Outage`): still meant to
    /// be playing, so pause stops the wait.
    var isWaitingForNetwork: Bool {
        outage?.idle == true
    }

    /// Whether `videoId` is the playing track — as itself, or as the music
    /// video / song it stands for (`MusicSongVersions`): a list shows the
    /// MV while its song plays, and the other way round.
    func isCurrent(_ videoId: String) -> Bool {
        guard let id = current?.id else {
            return false
        }
        return id == videoId
            || MusicSongVersions.songId(of: videoId) == id
            || MusicSongVersions.songId(of: id) == videoId
    }

    /// The track that plays when this one ends.
    var nextTrack: Video? {
        plannedNext()?.track
    }

    /// The head of the queue, else of the context; the context from its
    /// start for repeat-all. A shuffled restart is drawn at random when it
    /// happens, so it has no known first track to preload.
    private var naturalNext: Video? {
        if let track = queue.first ?? upcoming.first {
            return track
        }
        guard repeatMode == .all, !isShuffled else {
            return nil
        }
        return context.first
    }

    /// What plays next: the natural next track, or a song on the device
    /// standing in for it (`standIn`) while it cannot play — the device is
    /// offline, or an outage is being bridged and the network has not
    /// proved itself back (the next track preloaded, when preloading is on).
    private func plannedNext() -> (track: Video, standsIn: Bool)? {
        let natural = naturalNext
        let naturalPlays = natural.map(Self.playableOffline) ?? false
        let blocked: Bool
        if let outage, outage.bridging {
            let unproven = natural.map { OPMusicSettings.cacheNext && !prefetcher.isReady(for: $0) } ?? true
            blocked = !naturalPlays && (!outage.reachable || unproven)
        } else {
            blocked = NetworkType.isOffline && !naturalPlays
        }
        if blocked, let song = standIn() {
            return (song, true)
        }
        if blocked, outage?.reachable != true {
            return nil
        }
        return natural.map { ($0, false) }
    }

    /// Downloaded, or cached in full — as itself or as its song version.
    private static func playableOffline(_ track: Video) -> Bool {
        isOnDevice(track.id) || MusicSongVersions.songId(of: track.id).map(isOnDevice) == true
    }

    private static func isOnDevice(_ videoId: String) -> Bool {
        DownloadStore.isDownloaded(videoId) || OPAudioCache.isComplete(forVideoId: videoId)
    }

    var currentTime: TimeInterval {
        let seconds = CMTimeGetSeconds(player.currentTime())
        return seconds.isFinite ? seconds : 0
    }

    var duration: TimeInterval {
        guard let item = player.currentItem else {
            return 0
        }
        let seconds = CMTimeGetSeconds(item.duration)
        return seconds.isFinite ? seconds : 0
    }

    /// The album's cover for the album's own tracks; anything queued in
    /// from elsewhere shows its own artwork.
    func artworkURL(for video: Video?) -> URL? {
        let fromAlbum = video.map { track in context.contains { $0.id == track.id } } ?? false
        let album = fromAlbum ? collectionArtworkURL : nil
        return URL(string: Self.fullSize(album ?? video?.thumbnailURL ?? ""))
    }

    /// A track keeps the thumbnail of the list it came from, and YouTube
    /// Music's lists ask for 60–120 px ("…=w120-h120-l90-rj"): blurry in
    /// the full player. Google's image server makes any size the URL asks.
    /// Not on mobile data: the list's size is enough there (by design).
    static func fullSize(_ url: String) -> String {
        guard url.contains("googleusercontent.com"), !NetworkType.isCellular else {
            return url
        }
        return url.replacingOccurrences(
            of: "=(w\\d+-h\\d+|s\\d+)", with: "=w720-h720", options: .regularExpression
        )
    }

    override private init() {
        super.init()
        configureFacade()
        NotificationCenter.default.addObserver(
            forName: .OPSleepTimerDidFire, object: nil, queue: .main
        ) { [weak self] _ in
            self?.sleep()
        }
        NotificationCenter.default.addObserver(
            forName: .OPSleepTimerDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.updateItemEndAction()
            self?.endCrossfade()
            // Changed or turned off mid-fade: back to the full level.
            self?.sleepFadeTick()
        }
        NotificationCenter.default.addObserver(
            forName: MusicNativeNames.didLearnNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.applyNativeNames()
        }
        NotificationCenter.default.addObserver(
            forName: .OPMusicSettingsDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            if let self, let track = self.current {
                self.applyLevel(for: track)
            }
        }
        observe(player)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(saveSession),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(itemDidFinish(_:)),
            name: .AVPlayerItemDidPlayToEndTime,
            object: nil
        )
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main
        ) { [weak self] note in
            self?.itemDidFail(note)
        }
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.didBecomeActiveNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.updateKeepAlive()
            }
        }
    }

    /// Time, play state and end-of-song behaviour follow the playing player.
    private func observe(_ player: AVQueuePlayer) {
        if let timeObserver, let observed {
            observed.removeTimeObserver(timeObserver)
        }
        observed = player
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            NowPlayingService.shared.updatePosition(CMTimeGetSeconds(time))
            self?.saveSessionIfDue()
            self?.prefetchIfDue()
            self?.scheduleCrossfadeIfDue()
            self?.updateItemEndAction()
            self?.startSleepFadeIfDue()
        }
        rateObservation = player.observe(\.timeControlStatus) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.watchStall()
                self?.postChange()
            }
        }
    }

    /// The facade never reports to YouTube: the TV sign-in's history would
    /// carry every song into video recommendations. `reporter` sends plays
    /// to YouTube Music's history instead, or nowhere.
    private func configureFacade() {
        facade.context = self
        facade.tracksWatchtime = false
    }

    /// Plays reported with the web account (YouTube Music's history); with
    /// no web account, plays are not reported at all.
    private lazy var reporter: WatchtimeTracker = {
        let tracker = WatchtimeTracker()
        tracker.timeProvider = { [weak self] in
            self?.currentTime ?? 0
        }
        tracker.durationProvider = { [weak self] in
            self?.duration ?? 0
        }
        tracker.authHeaders = {
            OPMusicWebAccount.headers(forOrigin: "https://music.youtube.com") ?? [:]
        }
        return tracker
    }()

    private func report(_ track: Video) {
        reporter.stop()
        guard OPMusicWebAccount.signedIn else {
            AppLog.player("music: \(track.id) not reported (no web account)")
            return
        }
        YTMusicPublic.playbackTracking(videoId: track.id) { [weak self] urls in
            guard let self, let urls, self.current?.id == track.id else {
                return
            }
            self.reporter.start(videoId: track.id, urls: urls)
        }
    }

    // MARK: - Starting

    func play(
        tracks: [Video],
        startAt start: Int,
        shuffled: Bool = false,
        artworkURL: String? = nil,
        collection: Playlist? = nil,
        endless continuation: String? = nil,
        title: String? = nil
    ) {
        guard tracks.indices.contains(start) else {
            return
        }
        endOutage(purging: false, "a new start")
        resume = nil
        currentFromQueue = false
        radio = title != nil || continuation != nil
            ? Radio(continuation: continuation, isMix: false, signedIn: false, playlistId: nil, joinsContext: true)
            : nil
        radioGeneration += 1
        isFetchingRadio = false
        waitingForMore = false
        mixIds = []
        // Not the app's own lists (Downloads), which YouTube does not know.
        collectionId = collection.flatMap { $0.id.hasPrefix("opaline.") ? nil : $0.id }
        if let collection {
            // Feeds Speed dial.
            MusicPlayLog.shared.recordCollection(collection)
        }
        context = tracks
        contextTitle = title ?? collection?.title
        collectionArtworkURL = artworkURL
        isShuffled = shuffled
        current = tracks[start]
        history = shuffled ? [] : Array(tracks[..<start])
        let rest = shuffled
            ? tracks.enumerated().filter { $0.offset != start }.map(\.element).shuffled()
            : Array(tracks[(start + 1)...])
        upcoming = rest
        consecutiveFailures = 0
        load()
    }

    // MARK: - The queue

    /// Top of the queue. With nothing playing it simply plays.
    func playNext(_ track: Video) {
        guard isActive else {
            play(tracks: [track], startAt: 0)
            return
        }
        queue.insert(track, at: 0)
        queueChanged()
    }

    /// Bottom of the queue.
    func addToQueue(_ track: Video) {
        guard isActive else {
            play(tracks: [track], startAt: 0)
            return
        }
        queue.append(track)
        queueChanged()
    }

    func removeFromQueue(at position: Int) {
        guard queue.indices.contains(position) else {
            return
        }
        queue.remove(at: position)
        queueChanged()
    }

    func moveInQueue(from source: Int, to destination: Int) {
        guard queue.indices.contains(source), queue.indices.contains(destination) else {
            return
        }
        queue.insert(queue.remove(at: source), at: destination)
        queueChanged()
    }

    func removeUpcoming(at position: Int) {
        guard upcoming.indices.contains(position) else {
            return
        }
        upcoming.remove(at: position)
        queueChanged()
    }

    func moveUpcoming(from source: Int, to destination: Int) {
        guard upcoming.indices.contains(source), upcoming.indices.contains(destination) else {
            return
        }
        upcoming.insert(upcoming.remove(at: source), at: destination)
        queueChanged()
    }

    /// Plays a queue entry now; the ones above it count as played.
    func jumpInQueue(to position: Int) {
        guard queue.indices.contains(position) else {
            return
        }
        endOutage(purging: true, "a queue entry chosen")
        retireCurrent()
        current = queue[position]
        currentFromQueue = true
        queue.removeFirst(position + 1)
        load()
    }

    /// Plays a context entry now; the queue stays, the skipped ones go.
    func jumpInUpcoming(to position: Int) {
        guard upcoming.indices.contains(position) else {
            return
        }
        endOutage(purging: true, "an upcoming track chosen")
        retireCurrent()
        history += upcoming[..<position]
        current = upcoming[position]
        currentFromQueue = false
        upcoming.removeFirst(position + 1)
        load()
    }

    func toggleShuffle() {
        isShuffled.toggle()
        if isShuffled {
            upcoming.shuffle()
        } else {
            // Back to album order, from after the playing track; the
            // recommendations after it keep their place at the end.
            let playing = current.map { track in context.firstIndex { $0.id == track.id } } ?? nil
            let remaining = Set(upcoming.map(\.id))
            let inContext = Set(context.map(\.id))
            upcoming = context.enumerated()
                .filter { remaining.contains($0.element.id) && $0.offset > (playing ?? -1) }
                .map(\.element)
                + upcoming.filter { !inContext.contains($0.id) }
        }
        queueChanged()
    }

    func cycleRepeat() {
        switch repeatMode {
        case .off:
            repeatMode = .all
            dropEndless()
        case .all:
            repeatMode = .one
        case .one:
            repeatMode = .off
        }
        updateItemEndAction()
        queueChanged()
    }

    /// Repeat-all turned on after the album or playlist ran out: the mix
    /// (or recommendations) already lined up after it would play before
    /// the restart, so it goes, and the context's own title comes back.
    /// Artist radio is the context itself and stays.
    private func dropEndless() {
        guard let radio, !radio.joinsContext else {
            return
        }
        let contextIds = Set(context.map(\.id))
        upcoming.removeAll { !contextIds.contains($0.id) }
        self.radio = nil
        radioGeneration += 1
        isFetchingRadio = false
        waitingForMore = false
        contextTitle = titleBeforeEndless ?? contextTitle
    }

    private func queueChanged() {
        resolveAhead()
        topUpRadioIfNeeded()
        postChange()
        saveContext()
        // The preloaded track may no longer be the next one.
        prefetcher.discard(unless: preloadTarget, from: player)
        prefetchIfDue()
    }

    /// Keeps endless playback a few tracks ahead. Once an album, playlist
    /// or single song has nothing left (and repeat-all is off), it turns
    /// into a mix: YouTube Music's automix of a temporary playlist of the
    /// last songs played (`mixSeeds`), signed in with the web account when
    /// there is one. A mix is never continued: when it runs low, the next
    /// one is seeded from the plays again, mix tracks included but held to
    /// a share. With "YouTube Music's recommendations" on (and the web
    /// account), YouTube Music's own continuation instead: the finished
    /// playlist's automix as the account sees it. Radio from the last track
    /// if either fails. Offline, or in an outage, there is nothing to fetch:
    /// songs on the device stand in (`standIn`) until the network is back.
    private func topUpRadioIfNeeded() {
        guard let current, !NetworkType.isOffline, outage == nil else {
            return
        }
        if radio == nil, queue.isEmpty, upcoming.isEmpty, repeatMode != .all {
            let account = OPMusicSettings.accountRecommendations && OPMusicWebAccount.signedIn
            radio = Radio(
                continuation: nil,
                isMix: !account,
                signedIn: OPMusicWebAccount.signedIn,
                playlistId: account ? collectionId : nil,
                joinsContext: false
            )
            titleBeforeEndless = contextTitle
            contextTitle = account ? "recommendations" : "your mix"
            AppLog.player(
                "music: context done, "
                    + (account ? "YouTube Music's recommendations after \(collectionId ?? current.id)" : "mixing from recent plays")
            )
        }
        guard let radio, !isFetchingRadio, upcoming.count < 5 else {
            return
        }
        let seed = upcoming.last ?? current
        isFetchingRadio = true
        let generation = radioGeneration
        let known = Set((history + [current] + queue + upcoming + recent.map(\.video)).map(\.id))
        let plainRadio = { [weak self] in
            YTMusicPublic.watchQueue(
                playlistId: "RDAMVM\(seed.id)",
                videoId: seed.id,
                signedIn: radio.signedIn
            ) { self?.receive($0, generation: generation, known: known) }
        }
        if let continuation = radio.continuation {
            YTMusicPublic.watchQueue(
                playlistId: nil,
                videoId: nil,
                continuation: continuation,
                signedIn: radio.signedIn
            ) { [weak self] in self?.receive($0, generation: generation, known: known) }
        } else if radio.isMix {
            let seeds = mixSeeds()
            AppLog.player("music: mix from \(seeds.count) recent plays, \(seeds.filter(\.fromMix).count) from mixes")
            YTMusicPublic.temporaryPlaylist(videoIds: seeds.map(\.video.id)) { [weak self] list in
                guard let self, generation == self.radioGeneration else {
                    return
                }
                guard let list else {
                    plainRadio()
                    return
                }
                YTMusicPublic.watchQueue(playlistId: "RDAMPL\(list)", videoId: nil, signedIn: radio.signedIn) {
                    [weak self] in self?.receive($0, generation: generation, known: known, orElse: plainRadio)
                }
            }
        } else if let playlistId = radio.playlistId {
            self.radio?.playlistId = nil
            // The playlist's own queue names its automix (`RDAMPL…`, only
            // when the account can read it — asking for `RDAMPL<id>`
            // directly answers even for one it cannot, with unrelated
            // tracks).
            YTMusicPublic.watchQueue(playlistId: playlistId, videoId: nil, signedIn: true) { [weak self] probe in
                guard let self, generation == self.radioGeneration else {
                    return
                }
                guard let automix = probe?.automix else {
                    AppLog.player("music: no automix for \(playlistId), radio from the last track")
                    plainRadio()
                    return
                }
                YTMusicPublic.watchQueue(
                    playlistId: automix.playlistId, videoId: nil, params: automix.params, signedIn: true
                ) { [weak self] in self?.receive($0, generation: generation, known: known, orElse: plainRadio) }
            }
        } else {
            plainRadio()
        }
    }

    /// New tracks for endless playback; `fallback` is tried instead when
    /// there are none.
    private func receive(
        _ slice: MusicWatchQueue?,
        generation: Int,
        known: Set<String>,
        orElse fallback: (() -> Void)? = nil
    ) {
        guard generation == radioGeneration, let radio else {
            return
        }
        let fresh = (slice?.tracks ?? []).filter { !known.contains($0.id) }
        AppLog.player("music: endless top-up, \(fresh.count) new tracks")
        guard !fresh.isEmpty else {
            if let fallback {
                fallback()
                return
            }
            isFetchingRadio = false
            if radio.continuation != nil {
                // The queue's own list ended: go on as radio.
                self.radio?.continuation = nil
                topUpRadioIfNeeded()
            } else {
                waitingForMore = false
            }
            return
        }
        isFetchingRadio = false
        self.radio?.continuation = radio.isMix ? nil : slice?.continuation
        upcoming += fresh
        if radio.isMix {
            mixIds.formUnion(fresh.map(\.id))
        }
        if radio.joinsContext {
            context += fresh
        }
        guard waitingForMore else {
            queueChanged()
            return
        }
        waitingForMore = false
        advance(userInitiated: false)
    }

    /// The last songs played, newest first, at most `mixSeedShare` of them
    /// brought in by a mix.
    private func mixSeeds() -> [RecentPlay] {
        let playing = current.map { [RecentPlay(video: $0, fromMix: mixIds.contains($0.id))] } ?? []
        var seen = Set<String>()
        let newest = (playing + recent.reversed()).filter { seen.insert($0.video.id).inserted }
        let fromMix = min(Self.mixSeedShare, newest.filter(\.fromMix).count)
        var mixTaken = 0
        var chosenTaken = 0
        return newest.filter { play in
            if play.fromMix {
                mixTaken += 1
                return mixTaken <= fromMix
            }
            chosenTaken += 1
            return chosenTaken <= Self.mixSeedCount - fromMix
        }
    }

    /// A play: the local log, the mix seeds, and YouTube Music's history.
    private func recordPlay(_ track: Video) {
        report(track)
        OPAudioCache.notePlay(ofVideoId: track.id)
        MusicPlayLog.shared.recordTrack(track)
        recent.removeAll { $0.video.id == track.id }
        recent.append(RecentPlay(video: track, fromMix: mixIds.contains(track.id)))
        // Only what a seed can use of each kind.
        var mixKept = 0
        var chosenKept = 0
        recent = recent.reversed().filter { play in
            if play.fromMix {
                mixKept += 1
                return mixKept <= Self.mixSeedShare
            }
            chosenKept += 1
            return chosenKept <= Self.mixSeedCount
        }.reversed()
        if let data = try? JSONEncoder().encode(recent) {
            UserDefaults.standard.set(data, forKey: Self.recentKey)
        }
    }

    /// The context from its first track again, for repeat-all.
    private func contextRestart() -> [Video] {
        isShuffled ? context.shuffled() : context
    }

    // MARK: - Transport

    func togglePlayPause() {
        // Play pressed before the song the sleep timer held back is ready:
        // the user wins.
        endCrossfade()
        holdNextStart = false
        if outage?.idle == true {
            // Pause while waiting for the network: stop waiting.
            cancelOutage()
            return
        }
        if player.timeControlStatus == .paused {
            if player.currentItem == nil, isActive, !isLoading {
                // A restored session: picks up where it was left.
                load(startAt: pendingStart)
            } else {
                player.play()
            }
        } else {
            player.pause()
        }
        postChange()
    }

    func next() {
        endCrossfade()
        advance(userInitiated: true)
    }

    /// Restarts the track when it is past its first seconds, like every
    /// music player; otherwise goes back to the one before.
    func previous() {
        endCrossfade()
        guard currentTime <= 3, let previous = history.popLast(), let playing = current else {
            seek(to: 0)
            return
        }
        endOutage(purging: true, "previous")
        // The track left goes back to the head of what comes next.
        if contextTitle != nil || !upcoming.isEmpty {
            upcoming.insert(playing, at: 0)
        } else {
            queue.insert(playing, at: 0)
        }
        current = previous
        currentFromQueue = false
        load()
    }

    func seek(to seconds: TimeInterval) {
        endCrossfade()
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        NowPlayingService.shared.updatePosition(seconds)
    }

    /// Stops, and calls back (main queue) once the saved session is gone
    /// from disk as well: `stop` deletes it on the writer queue, which would
    /// otherwise race whatever is put there next (the Opaline import).
    func stop(then completion: @escaping () -> Void) {
        stop()
        sessionWriter.async {
            DispatchQueue.main.async(execute: completion)
        }
    }

    func stop() {
        endOutage(purging: false, "stopped")
        resume = nil
        AudioOnlyMode.soundOnly = false
        endCrossfade()
        sleepFadeTimer?.invalidate()
        sleepFadeTimer = nil
        holdNextStart = false
        reporter.stop()
        token.cancel()
        facade.reset()
        prefetcher.discard(unless: nil, from: player)
        player.pause()
        player.removeAllItems()
        playingItem = nil
        resourceLoader = nil
        current = nil
        queue = []
        upcoming = []
        context = []
        history = []
        contextTitle = nil
        mixIds = []
        collectionId = nil
        radio = nil
        radioGeneration += 1
        isFetchingRadio = false
        waitingForMore = false
        isLoading = false
        NowPlayingService.shared.endSession()
        UserDefaults.standard.removeObject(forKey: Self.sessionKey)
        sessionWriter.async {
            try? FileManager.default.removeItem(at: Self.contextFile)
        }
        postChange()
    }

    private func retireCurrent() {
        if let current {
            history.append(current)
        }
    }

    /// Moves `current` on to the next track per the queue rules (or a song
    /// standing in for it, see `plannedNext`). Returns false at the end of
    /// everything.
    private func step() -> Bool {
        guard let plan = plannedNext() else {
            if outage?.reachable == true {
                // Back online with nothing left: the mix is asked now, past
                // any request the outage left hanging.
                endOutage(purging: true, "back online at the end")
                radioGeneration += 1
                isFetchingRadio = false
            }
            return false
        }
        if plan.standsIn {
            if outage == nil {
                // Offline (no route at all): nothing to retry first.
                beginOutage(cutOff: nil, at: 0, since: Date(), "offline at \(naturalNext?.id ?? "the end")")
            }
            outage?.bridging = true
            retireCurrent()
            takeStandIn(plan.track)
            return true
        }
        if let outage, outage.reachable || !outage.bridging {
            endOutage(purging: true, "\(plan.track.id) next")
        }
        takeNatural()
        return true
    }

    /// The head of the queue, else of the context (from its start again for
    /// repeat-all) becomes `current`.
    private func takeNatural() {
        retireCurrent()
        if !queue.isEmpty {
            current = queue.removeFirst()
            currentFromQueue = true
        } else if !upcoming.isEmpty {
            current = upcoming.removeFirst()
            currentFromQueue = false
        } else {
            upcoming = contextRestart()
            current = upcoming.isEmpty ? current : upcoming.removeFirst()
            currentFromQueue = false
        }
    }

    private func advance(userInitiated: Bool) {
        let expected = nextTrack
        guard step() else {
            if outage != nil {
                // Nothing on the device to stand in: wait, alive, for the
                // network (`outageTick`).
                outage?.idle = true
                isLoading = true
                player.pause()
                postChange()
                return
            }
            // End of everything: stay on the last track, paused at its end —
            // unless recommendations are on their way (asked for now, if
            // nothing asked yet).
            topUpRadioIfNeeded()
            waitingForMore = isFetchingRadio
            player.pause()
            postChange()
            if waitingForMore {
                watchForMore()
            }
            return
        }
        // Preloaded already: switch to it without a new resolve.
        if let ready = prefetcher.take(for: current, expected: expected) {
            if userInitiated {
                player.advanceToNextItem()
            }
            adopt(ready)
            return
        }
        load()
    }

    @objc
    private func itemDidFinish(_ note: Notification) {
        guard let item = note.object as? AVPlayerItem, item === playingItem else {
            return
        }
        if stopsAfterCurrent {
            // The sleep timer waited for this song (or for the album or
            // playlist it ends): the next one is made ready, paused, so Play
            // goes on from there.
            holdNextStart = true
            OPSleepTimer.songDidEnd()
            advance(userInitiated: false)
            return
        }
        if repeatMode == .one {
            // The queue player would move on to the preloaded item.
            prefetcher.discard(unless: nil, from: player)
            guard player.currentItem === item else {
                // Repeat turned on as the song ended: the queue player has
                // already dropped it, so it loads again.
                load()
                return
            }
            seek(to: 0)
            player.play()
            return
        }
        // The queue player has already moved on to a preloaded item, if any.
        advance(userInitiated: false)
    }

    // MARK: - Loading

    /// The item of the track in `current`, which the end notification must
    /// match (the queue player also holds the preloaded one). Strong: the
    /// queue player drops a finished item, possibly before its end
    /// notification is handled.
    private var playingItem: AVPlayerItem?

    /// Every track starts at `startAt` (0 unless resuming), never at the
    /// position the watch history remembers for that video.
    private func load(startAt: TimeInterval = 0) {
        guard let track = current else {
            return
        }
        // A music video's song version (`MusicSongVersions`) plays instead.
        // Not looked up yet: ask, but start within a few seconds either way.
        if MusicSongVersions.isEnabled, !MusicSongVersions.isResolved(track),
           !NetworkType.isOffline, !DownloadStore.isDownloaded(track.id),
           !OPAudioCache.isComplete(forVideoId: track.id) {
            isLoading = true
            postChange()
            var started = false
            let start = { [weak self] in
                guard let self, !started, self.current?.id == track.id else {
                    return
                }
                started = true
                self.beginLoad(startAt: startAt)
            }
            MusicSongVersions.resolve(track) { _ in start() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: start)
            return
        }
        beginLoad(startAt: startAt)
    }

    /// Swaps in the song version when one is known — unless the music video
    /// is downloaded or cached and the song is not, which would need the
    /// network.
    private func applySongVersion(_ track: Video) -> Video {
        guard let song = MusicSongVersions.known(track),
              !Self.isOnDevice(track.id) || Self.isOnDevice(song.id)
        else {
            return track
        }
        return song
    }

    /// The next few tracks under their song versions before they are
    /// preloaded, so the switch stays gapless: known ones at once, the
    /// others looked up.
    private func resolveAhead() {
        guard MusicSongVersions.isEnabled else {
            return
        }
        let ahead = Array((queue + upcoming).prefix(3))
        var swapped = false
        for track in ahead {
            let song = applySongVersion(track)
            if song.id != track.id {
                replace(track.id, with: song)
                swapped = true
            } else if !MusicSongVersions.isResolved(track), !NetworkType.isOffline {
                MusicSongVersions.resolve(track) { [weak self] song in
                    guard let self, song != nil else {
                        return
                    }
                    let applied = self.applySongVersion(track)
                    if applied.id != track.id {
                        self.replace(track.id, with: applied)
                        self.queueChanged()
                    }
                }
            }
        }
        if swapped {
            postChange()
        }
    }

    private func replace(_ videoId: String, with song: Video) {
        func swap(_ list: inout [Video]) {
            list = list.map { $0.id == videoId ? song : $0 }
        }
        swap(&queue)
        swap(&upcoming)
        swap(&context)
    }

    private func beginLoad(startAt: TimeInterval) {
        endCrossfade()
        guard var track = current else {
            return
        }
        var startAt = startAt
        let song = applySongVersion(track)
        if song.id != track.id {
            AppLog.player("music: \(track.id) → song version \(song.id)")
            replace(track.id, with: song)
            current = song
            track = song
        }
        if let resume, resume.id == track.id {
            // The track an outage cut off, from where it was.
            startAt = resume.at
            self.resume = nil
        }
        pendingStart = 0
        waitingForMore = false
        loadBegan = (Date(), startAt)
        WatchProgressStore.shared.setLinkStart(seconds: startAt, forVideoId: track.id)
        token.cancel()
        token = CancellationToken()
        facade.reset()
        prefetcher.discard(unless: nil, from: player)
        player.pause()
        player.removeAllItems()
        resourceLoader = nil
        isLoading = true
        postChange()
        saveSession()
        saveContext()
        // A video left playing from video mode ends with the first song.
        VideoRouter.shared.clearCurrentWatch()
        // Sources build the audio-only entry playlist while this is set.
        AudioOnlyMode.isEnabled = true
        AudioOnlyMode.soundOnly = true
        AppLog.player("music: loading \(track.id), \(queue.count) queued, \(upcoming.count) upcoming")
        topUpRadioIfNeeded()
        facade.start(
            videoId: track.id,
            apiClient: ServiceContainer.watch,
            cancellationToken: token
        )
        watchLoad(track, token: token)
    }

    /// A preloaded track that has not started a few seconds after taking
    /// over (an item AVQueuePlayer never prepared, e.g. a stream that was
    /// queued behind a file) is loaded afresh instead of staying silent.
    private func checkStarted(_ item: AVPlayerItem, track: Video) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.outage == nil, self.playingItem === item, self.current?.id == track.id,
                  self.player.currentItem === item, self.player.timeControlStatus != .paused,
                  CMTimeGetSeconds(item.currentTime()) < 0.5
            else {
                return
            }
            AppLog.player(
                "music: preloaded \(track.id) did not start (status \(item.status.rawValue),"
                    + " \(item.error.map { "\($0)" } ?? "no error")): loading it again"
            )
            self.load()
        }
    }

    /// Takes over a preloaded track: its facade becomes the player's own,
    /// so recovery and watch time follow the track that plays.
    private func adopt(_ ready: Prefetcher.Ready, fadingOut outgoing: AVQueuePlayer? = nil, over seconds: TimeInterval = 0) {
        guard let track = current else {
            return
        }
        AppLog.player("music: playing preloaded \(track.id)" + (outgoing == nil ? "" : ", crossfading \(Int(seconds)) s"))
        if let outgoing {
            // The song before keeps its stream until it has faded out.
            beginFade(from: outgoing, to: track, over: seconds)
        } else {
            endCrossfade()
            token.cancel()
            facade.reset()
        }
        token = ready.token
        facade = ready.facade
        configureFacade()
        resourceLoader = ready.resourceLoader
        playingItem = ready.item
        isLoading = false
        consecutiveFailures = 0
        recordPlay(track)
        if let resume, resume.id == track.id {
            ready.item.seek(to: CMTime(seconds: resume.at, preferredTimescale: 600), completionHandler: nil)
            self.resume = nil
        }
        soundStarted()
        if player.currentItem !== ready.item {
            // The end notice can come before the queue has moved on. Queued
            // already, the song may have started: taken out and put back, it
            // played its first tenth of a second again. The queue moves on.
            let queued = player.items().contains(ready.item)
            AppLog.player(String(
                format: "music: %@ handed over %@ at %.2f s", track.id,
                queued ? "from the queue" : "afresh", CMTimeGetSeconds(ready.item.currentTime())
            ))
            if queued {
                while let head = player.currentItem, head !== ready.item {
                    player.remove(head)
                }
            } else {
                player.removeAllItems()
                player.insert(ready.item, after: nil)
            }
        }
        checkStarted(ready.item, track: track)
        if outgoing == nil {
            applyLevel(for: track)
        }
        if holdNextStart {
            holdNextStart = false
            player.pause()
        } else {
            player.play()
        }
        // As `load` does: a preloaded last track must still start the mix,
        // or playback stops after it.
        topUpRadioIfNeeded()
        beginNowPlaying(track, duration: ready.duration)
        saveSession()
        saveContext()
        postChange()
    }

    /// The sleep timer ran out. A timed one has faded the music out over
    /// its last minute already (`sleepFadeTick`); ending with a song, it is
    /// paused already.
    private func sleep() {
        AppLog.player("music: sleep timer, pausing")
        endCrossfade()
        sleepFadeTimer?.invalidate()
        sleepFadeTimer = nil
        player.pause()
        if let current {
            applyLevel(for: current)
        }
        postChange()
    }

    /// How far the sleep timer's fade has brought the volume down: 1 until
    /// its last minute, then down to 0 — squared, so it sounds even rather
    /// than dropping off at the end.
    private var sleepFactor: Float {
        guard let fire = OPSleepTimer.fireDate else {
            return 1
        }
        let left = fire.timeIntervalSinceNow / OPSleepTimer.fadeSeconds
        return left >= 1 ? 1 : Float(pow(max(left, 0), 2))
    }

    private var sleepFadeTimer: Timer?

    /// From the periodic observer: within the fade, a finer timer takes over.
    private func startSleepFadeIfDue() {
        guard sleepFadeTimer == nil, sleepFactor < 1 else {
            return
        }
        AppLog.player("music: sleep timer, fading out")
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.sleepFadeTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        sleepFadeTimer = timer
    }

    /// The playing song at its level times the fade; ends with the fade.
    private func sleepFadeTick() {
        if sleepFactor >= 1 {
            sleepFadeTimer?.invalidate()
            sleepFadeTimer = nil
        }
        // A crossfade sets the volumes itself, at the same factor.
        if fade == nil, let current {
            player.volume = targetVolume(for: current)
        }
    }

    /// Whether the queue player must stop at the end of this song instead
    /// of moving on: the sleep timer waits for it, or for the end of the
    /// album or playlist and nothing of it is left (what comes next is the
    /// mix, or nothing).
    private var stopsAfterCurrent: Bool {
        if OPSleepTimer.endOfSong {
            return true
        }
        guard OPSleepTimer.endOfContext, repeatMode != .all else {
            return false
        }
        guard let next = nextTrack else {
            return true
        }
        return queue.isEmpty && !context.contains { $0.id == next.id }
    }

    /// Repeat-one keeps the finished item (`.none`): with `.advance` the
    /// queue player drops it at its end, before `itemDidFinish` could seek
    /// it back to 0, and playback just stopped.
    private func updateItemEndAction() {
        let action: AVPlayer.ActionAtItemEnd
        if stopsAfterCurrent {
            action = .pause
        } else if repeatMode == .one {
            action = .none
        } else {
            action = .advance
        }
        if player.actionAtItemEnd != action {
            player.actionAtItemEnd = action
        }
    }

    /// Whether "End of album/playlist" means anything: an album or playlist
    /// is playing, not a radio or the mix after one.
    var playsCollection: Bool {
        radio == nil && !context.isEmpty
    }

    /// The song after the one the sleep timer waited for: loaded, not played.
    private var holdNextStart = false

    // MARK: - Crossfade

    /// The song fading out under the next one: its player and the stream
    /// behind it, released when the fade ends.
    private struct Fade {
        let player: AVQueuePlayer
        let facade: PlaybackFacade
        let token: CancellationToken
        let resourceLoader: AVAssetResourceLoaderDelegate?
        let timer: Timer
    }

    private var fade: Fade?
    private weak var crossfadeScheduledFor: AVPlayerItem?

    /// Within a second or so of the fade point: starts it on time (the
    /// periodic observer only ticks every second).
    private func scheduleCrossfadeIfDue() {
        let seconds = OPMusicSettings.crossfadeSeconds
        guard seconds > 0, fade == nil, let item = playingItem, item === player.currentItem,
              crossfadeScheduledFor !== item, duration > 0
        else {
            return
        }
        let remaining = duration - currentTime
        guard remaining > seconds, remaining - seconds < 1.5 else {
            return
        }
        crossfadeScheduledFor = item
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining - seconds) { [weak self] in
            guard let self, self.playingItem === item else {
                return
            }
            self.startCrossfade(over: seconds)
        }
    }

    /// The preloaded song starts on the spare player and fades in while this
    /// one fades out; then the two swap. Albums stay gapless (live albums,
    /// songs that run into each other), and so does anything not ready.
    private func startCrossfade(over seconds: TimeInterval) {
        let remaining = duration - currentTime
        // Seeked since it was scheduled: try again at the new fade point.
        guard abs(remaining - seconds) < 0.75 else {
            crossfadeScheduledFor = nil
            return
        }
        let album = collectionId.map { $0.hasPrefix("MPREb") || $0.hasPrefix("OLAK5uy") } ?? false
        guard player.rate > 0, !isLoading, repeatMode != .one, !stopsAfterCurrent, !holdNextStart,
              !(album && queue.isEmpty),
              let expected = nextTrack, prefetcher.isReady(for: expected)
        else {
            return
        }
        guard step(), let ready = prefetcher.take(for: current, expected: expected) else {
            load()
            return
        }
        let outgoing = player
        // It waited behind the song fading out; an item cannot move to
        // another player, so the spare one gets its own on the same asset.
        outgoing.remove(ready.item)
        let item = AVPlayerItem(asset: ready.item.asset)
        PlaybackBufferPolicy.configure(item: item)
        item.preferredForwardBufferDuration = Self.bufferSeconds
        let incoming = spare
        incoming.removeAllItems()
        incoming.volume = 0
        incoming.insert(item, after: nil)
        spare = outgoing
        player = incoming
        observe(incoming)
        adopt(
            Prefetcher.Ready(
                track: ready.track, item: item, resourceLoader: ready.resourceLoader,
                duration: ready.duration, facade: ready.facade, token: ready.token
            ),
            fadingOut: outgoing,
            over: seconds
        )
    }

    /// Equal-power curves, so the sum does not dip in the middle.
    private func beginFade(from outgoing: AVQueuePlayer, to track: Video, over seconds: TimeInterval) {
        let from = outgoing.volume
        let steps = max(Int(seconds * 20), 1)
        var step = 0
        let timer = Timer(timeInterval: seconds / Double(steps), repeats: true) { [weak self] _ in
            step += 1
            let progress = min(Double(step) / Double(steps), 1)
            outgoing.volume = from * Float(cos(progress * .pi / 2))
            if let self {
                self.player.volume = self.targetVolume(for: track) * Float(sin(progress * .pi / 2))
            }
            if step >= steps {
                self?.endCrossfade()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fade = Fade(player: outgoing, facade: facade, token: token, resourceLoader: resourceLoader, timer: timer)
    }

    /// Finishes a running fade at once: the song before stops, the new one
    /// is at its level. Anything the user does during a fade ends it first.
    private func endCrossfade() {
        guard let fade else {
            return
        }
        self.fade = nil
        fade.timer.invalidate()
        fade.player.pause()
        fade.player.removeAllItems()
        fade.player.volume = 1
        fade.token.cancel()
        fade.facade.reset()
        if let current {
            applyLevel(for: current)
        }
    }

    /// Artists' Japanese names (`MusicNativeNames`) on everything queued,
    /// once they are known — a queue fetched before is renamed in place.
    private func applyNativeNames() {
        let before = [current?.channelName] + queue.map(\.channelName) + upcoming.map(\.channelName)
        current = current.map(MusicNativeNames.renamed)
        queue = queue.map(MusicNativeNames.renamed)
        upcoming = upcoming.map(MusicNativeNames.renamed)
        context = context.map(MusicNativeNames.renamed)
        history = history.map(MusicNativeNames.renamed)
        let after = [current?.channelName] + queue.map(\.channelName) + upcoming.map(\.channelName)
        guard before != after else {
            return
        }
        if let current {
            beginNowPlaying(current, duration: duration > 0 ? duration : nil)
        }
        postChange()
    }

    /// Louder songs turned down to YouTube's target (setting "Same volume
    /// for every song"); on both start paths, the preloaded one included.
    func applyLevel(for track: Video) {
        let volume = targetVolume(for: track)
        if player.volume != volume {
            AppLog.player(String(format: "music: volume %.2f for %@", volume, track.id))
        }
        player.volume = volume
    }

    /// The song's level, times the sleep timer's fade when one is running.
    private func targetVolume(for track: Video) -> Float {
        (OPMusicSettings.levelVolume ? PlayerLoudness.volume(for: track.id) : 1) * sleepFactor
    }

    private func beginNowPlaying(_ track: Video, duration: Double?) {
        NowPlayingService.shared.beginSession(
            player: player,
            metadata: NowPlayingMetadata(
                title: track.title,
                channelName: track.channelName,
                duration: duration ?? 0,
                artworkURL: artworkURL(for: track)
            ),
            onNext: { [weak self] in self?.next() },
            onPrevious: { [weak self] in self?.previous() },
            onPause: { [weak self] in
                if self?.outage?.idle == true {
                    self?.cancelOutage()
                }
                self?.postChange()
            }
        )
    }

    /// How far ahead to buffer, per the music settings.
    static var bufferSeconds: TimeInterval {
        let seconds = OPMusicSettings.cacheSeconds
        // "Whole song": longer than any song, so nothing is held back.
        return seconds > 0 ? seconds : 3_600
    }

    // MARK: - Network outages

    /// The music stopped, or the next song never started, because the
    /// network does not answer: no route, every packet dropped, or a signal
    /// so weak that nothing arrives. For 30 s the track is retried (and the
    /// app kept running, `updateKeepAlive`); then songs on the device stand
    /// in (`standIn`) until the network is back, and the track cut off
    /// plays next, from where it stopped.
    private struct Outage {
        /// When the sound stopped (or the load began that never made any).
        let since: Date
        /// The track cut off, and where. None when recommendations were
        /// awaited, or offline, when the next track simply stays in place.
        let cutOff: Video?
        let position: TimeInterval
        var lastRetry: Date
        /// Songs on the device are standing in; the track cut off is back
        /// at the head of its list.
        var bridging = false
        /// Nothing audible: waiting for the network or for a stand-in.
        var idle = true
        /// The track cut off failed to load (no load of it is in flight).
        var loadFailed = false
        /// The latest probe got through.
        var reachable = false
        var lastProbe = Date.distantPast
        /// There was nothing on the device to stand in.
        var nothingToPlay = false
        /// Queue and context tracks played early as stand-ins. Their lists
        /// stay as they were meanwhile; once the network is back they are
        /// skipped this time round.
        var consumed: [String] = []
        /// Every stand-in played, so none plays twice.
        var played: Set<String> = []
    }

    private var outage: Outage?
    private var outageTimer: Timer?
    private var probing = false
    /// The track an outage cut off resumes here when it plays again.
    private var resume: (id: String, at: TimeInterval)?
    /// `current` came from the user's queue, not the context: where a track
    /// cut off goes back to.
    private var currentFromQueue = false
    /// When and where the current track's load began.
    private var loadBegan: (date: Date, at: TimeInterval) = (.distantPast, 0)
    /// The outage that ended last: a new one on the same track within
    /// seconds (a signal coming and going) counts from the first.
    private var lastOutage: (trackId: String?, since: Date, ended: Date)?
    private var stallGeneration = 0
    /// The track last reloaded after its stream failed, against a loop.
    private var lastFailedReload: (id: String, at: Date)?
    private static let bridgeAfter: TimeInterval = 30
    /// A load with no sound after this long is treated as an outage.
    private static let noSoundGrace: TimeInterval = 8

    /// What to preload: back from an outage, the track cut off — preloading
    /// it is what shows the network is usable again (`plannedNext`).
    private var preloadTarget: Video? {
        if let outage, outage.bridging, outage.reachable, let natural = naturalNext {
            return natural
        }
        return nextTrack
    }

    private func beginOutage(cutOff: Video?, at position: TimeInterval, since: Date, _ reason: String) {
        guard outage == nil else {
            return
        }
        var since = since
        if let last = lastOutage, last.trackId == cutOff?.id, Date().timeIntervalSince(last.ended) < 15 {
            since = min(since, last.since)
        }
        let left = max(0, Self.bridgeAfter - Date().timeIntervalSince(since))
        AppLog.player("music: outage — \(reason); songs on the device stand in after \(Int(left)) s")
        outage = Outage(since: since, cutOff: cutOff, position: position, lastRetry: Date())
        isLoading = true
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.outageTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        outageTimer = timer
        postChange()
    }

    /// `purging`: the tracks played early as stand-ins leave the lists now.
    private func endOutage(purging: Bool, _ reason: String) {
        guard let ended = outage else {
            return
        }
        outage = nil
        outageTimer?.invalidate()
        outageTimer = nil
        lastOutage = (ended.cutOff?.id, ended.since, Date())
        if purging {
            for id in ended.consumed {
                if let index = queue.firstIndex(where: { $0.id == id }) {
                    queue.remove(at: index)
                } else if let index = upcoming.firstIndex(where: { $0.id == id }) {
                    upcoming.remove(at: index)
                }
            }
        }
        AppLog.player(
            "music: outage over (\(reason)) after \(Int(Date().timeIntervalSince(ended.since))) s, "
                + "\(ended.played.count) stand-ins, \(purging ? ended.consumed.count : 0) skipped as played"
        )
        postChange()
    }

    /// Pause while waiting for the network: the wait ends, and the track cut
    /// off stays, paused where it stopped; Play loads it.
    private func cancelOutage() {
        guard let ended = outage else {
            return
        }
        token.cancel()
        facade.reset()
        prefetcher.discard(unless: nil, from: player)
        player.pause()
        player.removeAllItems()
        playingItem = nil
        resourceLoader = nil
        isLoading = false
        waitingForMore = false
        endOutage(purging: true, "paused")
        if ended.bridging, naturalNext != nil {
            // A stand-in had ended: the track cut off is next (`resume`).
            takeNatural()
        } else if current?.id == ended.cutOff?.id {
            pendingStart = ended.position
        }
        saveContext()
        saveSession()
        postChange()
    }

    private func outageTick() {
        guard let outage else {
            return
        }
        let now = Date()
        if !outage.bridging, !outage.nothingToPlay, now.timeIntervalSince(outage.since) >= Self.bridgeAfter {
            startBridge()
        }
        guard !probing, now.timeIntervalSince(outage.lastProbe) >= 5 else {
            return
        }
        self.outage?.lastProbe = now
        probing = true
        let answer = { [weak self] (reachable: Bool) in
            self?.probing = false
            self?.probed(reachable)
        }
        if NetworkType.isOffline {
            answer(false)
        } else {
            OPNetworkProbe.probe(answer)
        }
    }

    private func probed(_ reachable: Bool) {
        guard var outage else {
            return
        }
        let changed = outage.reachable != reachable
        outage.reachable = reachable
        self.outage = outage
        if changed {
            AppLog.player("music: network \(reachable ? "answers" : "out again")")
        }
        guard reachable else {
            return
        }
        if outage.bridging {
            if outage.idle {
                // Nothing playing: the track cut off, now.
                advance(userInitiated: false)
            } else if changed {
                // Preloaded behind the stand-in; it plays next if that works.
                queueChanged()
            }
            return
        }
        guard let cutOff = outage.cutOff else {
            // Recommendations were awaited: asked again.
            endOutage(purging: true, "back online, asking for more")
            radioGeneration += 1
            isFetchingRadio = false
            topUpRadioIfNeeded()
            waitingForMore = isFetchingRadio
            return
        }
        if player.timeControlStatus == .playing {
            endOutage(purging: true, "\(cutOff.id) playing again")
            isLoading = false
            postChange()
            return
        }
        // A load still in flight may only be slow (a weak signal): it gets
        // time before it is started over.
        guard outage.loadFailed || Date().timeIntervalSince(outage.lastRetry) >= 20 else {
            return
        }
        self.outage?.lastRetry = Date()
        self.outage?.loadFailed = false
        AppLog.player("music: retrying \(cutOff.id) at \(Int(outage.position)) s")
        load(startAt: outage.position)
    }

    /// 30 s without sound: a song on the device plays, and the track cut
    /// off goes back to the head of its list, to resume a little before
    /// where it stopped once the network is back.
    private func startBridge() {
        guard var outage else {
            return
        }
        guard let song = standIn() else {
            outage.nothingToPlay = true
            self.outage = outage
            AppLog.player("music: nothing on the device to stand in, waiting for the network")
            return
        }
        if let cutOff = outage.cutOff, current?.id == cutOff.id {
            if currentFromQueue {
                queue.insert(cutOff, at: 0)
            } else {
                upcoming.insert(cutOff, at: 0)
            }
            if outage.position > 5 {
                resume = (cutOff.id, outage.position - 2)
            }
        } else {
            retireCurrent()
        }
        outage.bridging = true
        self.outage = outage
        waitingForMore = false
        takeStandIn(song)
        load()
    }

    private func takeStandIn(_ track: Video) {
        if (queue + upcoming).contains(where: { $0.id == track.id }) {
            outage?.consumed.append(track.id)
        }
        outage?.played.insert(track.id)
        // Not chosen: kept to a share of the mix seeds.
        mixIds.insert(track.id)
        current = track
        currentFromQueue = false
        let ahead = queue.firstIndex { $0.id == track.id }.map { "queue #\($0 + 1)" }
            ?? upcoming.firstIndex { $0.id == track.id }.map { "upcoming #\($0 + 1)" }
            ?? context.firstIndex { $0.id == track.id }.map { "context #\($0 + 1), repeat-all" }
            ?? "from the device, \(track.musicArtist)"
        AppLog.player("music: \(track.id) stands in (\(ahead); \(upcoming.count) upcoming, \(context.count) in context)")
    }

    /// A song on the device for an outage: the first one further on from
    /// the playing track — the queue, then the rest of the context, never
    /// back to its start (unless repeat-all would go there) — played early,
    /// skipped later. Else the one most related to the track cut off (same
    /// artist), the most played first; so the most played of all when
    /// nothing is related, and any when nothing was counted. Songs played
    /// lately only when nothing else is as close.
    private func standIn() -> Video? {
        // A music video and its song are one track: lists that were swapped
        // to songs (the context) and lists that were not (history, the play
        // log) must agree, or an album's own first track comes back as an
        // "other" song.
        let key = { (id: String) in MusicSongVersions.songId(of: id) ?? id }
        let skip = Set(((outage?.played ?? []).union(current.map { [$0.id] } ?? [])).map(key))
        let usable = { (track: Video) in !skip.contains(key(track.id)) && Self.playableOffline(track) }
        let wraps = repeatMode == .all && !isShuffled ? context : []
        if let early = (queue + upcoming + wraps).first(where: usable) {
            return early
        }
        let plays = MusicPlayLog.shared.trackPlays()
        let saved = MusicDownloads.collections().flatMap { MusicDownloads.savedTracks(of: $0.id) ?? [] }
        // Not the context, nor what played before in it (history keeps the
        // ids as they were picked): its earlier tracks would loop the album
        // or playlist back to its start.
        let earlier = Set((context + history.suffix(context.count)).map { key($0.id) })
        var seen = Set<String>()
        let pool = (history.reversed() + recent.reversed().map(\.video) + plays.map(\.video) + saved)
            .filter { !earlier.contains(key($0.id)) && seen.insert(key($0.id)).inserted && usable($0) }
        guard !pool.isEmpty else {
            return nil
        }
        let counts = Dictionary(plays.map { (key($0.video.id), $0.plays.count) }, uniquingKeysWith: +)
        let lately = Set(history.suffix(30).map { key($0.id) })
        let anchor = outage?.cutOff ?? naturalNext ?? current
        func related(_ track: Video) -> Int {
            guard let anchor else {
                return 0
            }
            let sameArtist = anchor.channelId.map { $0 == track.channelId } ?? false
                || anchor.musicArtist == track.musicArtist
            return sameArtist ? 1 : 0
        }
        func rank(_ track: Video) -> (Int, Int, Int) {
            (related(track), lately.contains(key(track.id)) ? 0 : 1, counts[key(track.id)] ?? 0)
        }
        return pool.max { rank($0) < rank($1) || (rank($0) == rank($1) && $0.id > $1.id) }
    }

    /// Sound from a new item: a stand-in started, or the track cut off
    /// played after all.
    private func soundStarted() {
        guard let outage else {
            return
        }
        if outage.bridging {
            self.outage?.idle = false
        } else {
            endOutage(purging: true, "\(current?.id ?? "?") started")
        }
    }

    /// A load that brings no sound for a few seconds — a request hanging on
    /// a dead or crawling connection — starts the outage clock from when it
    /// began. The load goes on, and plays if it finishes in time.
    private func watchLoad(_ track: Video, token: CancellationToken) {
        let began = loadBegan
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.noSoundGrace) { [weak self] in
            guard let self, self.token === token, self.isLoading, self.outage == nil,
                  self.current?.id == track.id, !Self.playableOffline(track)
            else {
                return
            }
            self.beginOutage(
                cutOff: track, at: began.at, since: began.date,
                "\(track.id) still loading after \(Int(Self.noSoundGrace)) s"
            )
        }
    }

    /// Recommendations awaited at the end of everything that do not come.
    private func watchForMore() {
        let since = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.noSoundGrace) { [weak self] in
            guard let self, self.waitingForMore, self.outage == nil else {
                return
            }
            self.beginOutage(cutOff: nil, at: 0, since: since, "more tracks not arriving")
        }
    }

    /// The playing stream ran dry and stays dry for a few seconds: an
    /// outage, counted from when it stalled. Playing again by itself ends it.
    private func watchStall() {
        if let outage, !outage.bridging, outage.cutOff?.id == current?.id,
           player.timeControlStatus == .playing, playingItem === player.currentItem {
            endOutage(purging: true, "\(current?.id ?? "?") playing again")
            isLoading = false
            return
        }
        guard outage == nil, !isLoading, let track = current, let item = playingItem,
              item === player.currentItem,
              player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
              player.reasonForWaitingToPlay != .noItemToPlay,
              !Self.playableOffline(track)
        else {
            return
        }
        stallGeneration += 1
        let generation = stallGeneration
        let since = Date()
        let position = currentTime
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, generation == self.stallGeneration, self.outage == nil, self.playingItem === item,
                  self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            else {
                return
            }
            self.beginOutage(cutOff: track, at: position, since: since, "\(track.id) stalled at \(Int(position)) s")
        }
    }

    /// The playing stream gave up (a connection timed out mid-song): with
    /// no network an outage; otherwise loaded again from that point, once.
    private func itemDidFail(_ note: Notification) {
        guard let item = note.object as? AVPlayerItem, item === playingItem, let track = current else {
            return
        }
        let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
        AppLog.player("music: \(track.id) stopped playing — \(error.map { "\($0)" } ?? "no error")")
        let position = currentTime
        if outage != nil {
            if outage?.cutOff?.id == track.id {
                outage?.loadFailed = true
            }
            return
        }
        guard !Self.playableOffline(track) else {
            return
        }
        let since = Date()
        OPNetworkProbe.probe { [weak self] reachable in
            guard let self, self.playingItem === item, self.outage == nil else {
                return
            }
            guard !reachable else {
                if let last = self.lastFailedReload, last.id == track.id, Date().timeIntervalSince(last.at) < 60 {
                    self.skipFailed()
                } else {
                    self.lastFailedReload = (track.id, Date())
                    self.load(startAt: position)
                }
                return
            }
            self.beginOutage(cutOff: track, at: position, since: since, "\(track.id) stopped, no network")
            self.outage?.loadFailed = true
        }
    }

    /// Silence keeps the app running in the background while music should
    /// be playing but nothing is heard (`OPKeepAlive`): a suspended app
    /// could neither retry nor play a song from the device.
    private func updateKeepAlive() {
        let background = UIApplication.shared.applicationState == .background
        let silent = outage?.idle == true || isLoading || waitingForMore
            || (playingItem != nil && player.timeControlStatus == .waitingToPlayAtSpecifiedRate)
        let wanted = background && current != nil && silent
        guard wanted != OPKeepAlive.isActive else {
            return
        }
        OPKeepAlive.setActive(wanted)
        AppLog.player("music: keep-alive \(wanted ? "on" : "off")")
    }

    // MARK: - Preloading the next track

    /// Starts resolving the next track once the current one is within its
    /// last stretch — two minutes, or the buffer length if longer.
    private func prefetchIfDue() {
        guard OPMusicSettings.cacheNext,
              repeatMode != .one,
              !isLoading,
              let item = playingItem,
              item === player.currentItem
        else {
            return
        }
        let remaining = duration - currentTime
        // Back from an outage, the track cut off is preloaded at once: that
        // is what proves the network is usable (`plannedNext`).
        let lead = outage?.reachable == true ? .infinity : max(120, OPMusicSettings.cacheSeconds)
        // Timing first: during an outage, finding the next song is work.
        guard duration > 0, remaining <= lead, let next = preloadTarget else {
            return
        }
        prefetcher.prefetch(next, after: item, in: player)
    }

    // MARK: - Session

    private static let sessionKey = "musicPlayer_lastTrack"

    /// The track and where it was, saved every few seconds.
    private struct Session: Codable {
        let track: Video
        let artworkURL: String?
        let position: TimeInterval
    }

    /// What the track is playing in, saved only when it changes: a long
    /// playlist is too big to rewrite every few seconds.
    private struct SavedContext: Codable {
        let trackId: String
        let queue: [Video]
        let upcoming: [Video]
        let context: [Video]
        let history: [Video]
        let title: String?
        let mixIds: [String]
        let collectionId: String?
        let isShuffled: Bool
        let repeatMode: RepeatMode
        let radio: Radio?
    }

    private static let contextFile: URL = {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("MusicContext.json")
    }()

    private func saveContext() {
        guard let current else {
            return
        }
        MusicNativeNames.lookUp([current] + queue + upcoming)
        let saved = SavedContext(
            trackId: current.id,
            queue: queue,
            upcoming: upcoming,
            context: context,
            // Only the previous button reads it.
            history: Array(history.suffix(100)),
            title: contextTitle,
            mixIds: Array(mixIds),
            collectionId: collectionId,
            isShuffled: isShuffled,
            repeatMode: repeatMode,
            radio: radio
        )
        sessionWriter.async {
            guard let data = try? JSONEncoder().encode(saved) else {
                return
            }
            try? data.write(to: Self.contextFile, options: .atomic)
        }
    }

    private func saveSessionIfDue() {
        guard Date().timeIntervalSince(lastSaved) > 5 else {
            return
        }
        saveSession()
    }

    @objc
    func saveSession() {
        guard let current else {
            return
        }
        lastSaved = Date()
        let session = Session(
            track: current,
            artworkURL: collectionArtworkURL,
            position: player.currentItem == nil ? pendingStart : currentTime
        )
        if let data = try? JSONEncoder().encode(session) {
            UserDefaults.standard.set(data, forKey: Self.sessionKey)
        }
    }

    /// Brings back the last track, paused, without fetching until play.
    func restoreSessionIfNeeded() {
        guard !isActive,
              let data = UserDefaults.standard.data(forKey: Self.sessionKey),
              let session = try? JSONDecoder().decode(Session.self, from: data)
        else {
            return
        }
        current = session.track
        collectionArtworkURL = session.artworkURL
        pendingStart = session.position
        if let data = try? Data(contentsOf: Self.contextFile),
           let saved = try? JSONDecoder().decode(SavedContext.self, from: data),
           saved.trackId == session.track.id {
            queue = saved.queue
            upcoming = saved.upcoming
            context = saved.context
            history = saved.history
            contextTitle = saved.title
            mixIds = Set(saved.mixIds)
            collectionId = saved.collectionId
            isShuffled = saved.isShuffled
            repeatMode = saved.repeatMode
            radio = saved.radio
        }
        AppLog.player(
            "music: restored \(session.track.id) at \(Int(session.position))s"
                + " in \(contextTitle ?? "no context"), \(queue.count) queued, \(upcoming.count) upcoming"
        )
        postChange()
    }

    private func postChange() {
        updateKeepAlive()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}

// MARK: - PlaybackContext

extension MusicPlayer: PlaybackContext {
    func attachPrepared(_ prepared: PreparedPlayback, resumeAt: CMTime?) {
        guard let track = current else {
            return
        }
        consecutiveFailures = 0
        // Timed: a slow song start can freeze the screen.
        let started = CACurrentMediaTime()
        recordPlay(track)
        let recorded = CACurrentMediaTime()
        resourceLoader = prepared.resourceLoader
        PlaybackBufferPolicy.configure(item: prepared.item)
        prepared.item.preferredForwardBufferDuration = Self.bufferSeconds
        playingItem = prepared.item
        player.removeAllItems()
        player.insert(prepared.item, after: nil)
        if let resumeAt {
            player.seek(to: resumeAt)
        }
        applyLevel(for: track)
        if holdNextStart {
            holdNextStart = false
            player.pause()
        } else {
            player.playImmediately(atRate: 1)
        }
        let attached = CACurrentMediaTime()
        isLoading = false
        soundStarted()
        beginNowPlaying(track, duration: prepared.duration)
        let announced = CACurrentMediaTime()
        postChange()
        let total = CACurrentMediaTime() - started
        if total > 0.1 {
            AppLog.perf(String(
                format: "music start took %.0f ms: play log %.0f, player %.0f, now playing %.0f, screens %.0f",
                total * 1_000, (recorded - started) * 1_000, (attached - recorded) * 1_000,
                (announced - attached) * 1_000, (CACurrentMediaTime() - announced) * 1_000
            ))
        }
    }

    func updateStatusLabel(_ text: String) {}

    func showPlaybackError(_ message: String) {
        AppLog.player("music: \(current?.id ?? "?") failed — \(message)")
        guard let track = current, outage?.bridging != true, !Self.playableOffline(track) else {
            skipFailed()
            return
        }
        if outage != nil {
            // A retry of the track cut off: the outage goes on.
            outage?.loadFailed = true
            return
        }
        // The network, or this track? Spinning on meanwhile.
        let failedToken = token
        let began = loadBegan
        OPNetworkProbe.probe { [weak self] reachable in
            guard let self, self.token === failedToken, self.current?.id == track.id, self.outage == nil else {
                return
            }
            guard !reachable else {
                self.skipFailed()
                return
            }
            self.beginOutage(cutOff: track, at: began.at, since: began.date, "\(track.id) failed, no network")
            self.outage?.loadFailed = true
        }
    }

    /// A track that will not play is passed over, unless several in a row
    /// have failed.
    private func skipFailed() {
        isLoading = false
        consecutiveFailures += 1
        guard consecutiveFailures < 3, nextTrack != nil else {
            player.pause()
            postChange()
            return
        }
        advance(userInitiated: false)
    }

    func startObservingPlayerItem(_ item: AVPlayerItem) {}

    func stopObservingPlayerItem(_ item: AVPlayerItem) {}

    func setCaptionTracks(_ tracks: [SubtitleTrack]) {}
}

// MARK: - Prefetcher

/// Resolves one upcoming track through its own facade and slots its item in
/// behind the playing one, where the queue player buffers it ahead.
private final class Prefetcher: PlaybackContext {
    struct Ready {
        let track: Video
        let item: AVPlayerItem
        let resourceLoader: AVAssetResourceLoaderDelegate?
        let duration: Double?
        let facade: PlaybackFacade
        let token: CancellationToken
    }

    private var pending: (track: Video, facade: PlaybackFacade, token: CancellationToken)?
    private var ready: Ready?
    private weak var player: AVQueuePlayer?
    private weak var after: AVPlayerItem?

    func prefetch(_ track: Video, after item: AVPlayerItem, in player: AVQueuePlayer) {
        guard pending?.track.id != track.id, ready?.track.id != track.id else {
            return
        }
        discard(unless: nil, from: player)
        self.player = player
        after = item
        let facade = PlaybackFacade()
        facade.context = self
        facade.tracksWatchtime = false
        let token = CancellationToken()
        pending = (track, facade, token)
        AppLog.player("music: preloading next \(track.id)")
        WatchProgressStore.shared.setLinkStart(seconds: 0, forVideoId: track.id)
        facade.start(videoId: track.id, apiClient: ServiceContainer.watch, cancellationToken: token)
    }

    func isReady(for track: Video) -> Bool {
        ready?.track.id == track.id
    }

    /// The preloaded track, if it is the one now playing.
    func take(for current: Video?, expected: Video?) -> Ready? {
        guard let ready, ready.track.id == current?.id, expected?.id == current?.id else {
            return nil
        }
        self.ready = nil
        return ready
    }

    /// Drops the preloaded track unless it is `keep`.
    func discard(unless keep: Video?, from player: AVQueuePlayer) {
        if let keep, ready?.track.id == keep.id || pending?.track.id == keep.id {
            return
        }
        if let item = ready?.item, player.items().contains(item), player.currentItem !== item {
            player.remove(item)
        }
        pending?.token.cancel()
        pending = nil
        ready = nil
    }

    func attachPrepared(_ prepared: PreparedPlayback, resumeAt: CMTime?) {
        guard let pending, !pending.token.isCancelled, let player else {
            return
        }
        PlaybackBufferPolicy.configure(item: prepared.item)
        prepared.item.preferredForwardBufferDuration = MusicPlayer.bufferSeconds
        // Only behind the item it was meant to follow, which must still be
        // the one playing.
        guard let after, player.currentItem === after, player.canInsert(prepared.item, after: after) else {
            self.pending = nil
            return
        }
        // AVQueuePlayer never prepares a stream (our HLS) queued behind a
        // local file, and fails on reaching it (a downloaded
        // playlist, then the mix, stopped). Kept out of the queue, it is put
        // in when the file ends (`adopt`): a short gap, still no new resolve.
        let behindFile = (after.asset as? AVURLAsset)?.url.isFileURL == true
        let isFile = (prepared.item.asset as? AVURLAsset)?.url.isFileURL == true
        if behindFile, !isFile {
            AppLog.player("music: next \(pending.track.id) streams after a downloaded file: held out of the queue")
        } else {
            player.insert(prepared.item, after: after)
        }
        ready = Ready(
            track: pending.track,
            item: prepared.item,
            resourceLoader: prepared.resourceLoader,
            duration: prepared.duration,
            facade: pending.facade,
            token: pending.token
        )
        self.pending = nil
        AppLog.player("music: next \(pending.track.id) preloaded")
    }

    func updateStatusLabel(_ text: String) {}

    func showPlaybackError(_ message: String) {
        AppLog.player("music: preloading \(pending?.track.id ?? "?") failed — \(message)")
        pending = nil
    }

    func startObservingPlayerItem(_ item: AVPlayerItem) {}

    func stopObservingPlayerItem(_ item: AVPlayerItem) {}

    func setCaptionTracks(_ tracks: [SubtitleTrack]) {}
}
