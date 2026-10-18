import AVFoundation

/// Saving music for offline: audio-only downloads through the app's
/// downloader (a downloaded track then plays from the file — the playback
/// chain prefers it on its own), its lyrics into the lyrics cache, and the
/// albums and playlists downloaded, so the Library can list them offline.
enum MusicDownloads {
    private static let collectionsKey = "musicDownloads_collections"

    private struct SavedCollection: Codable {
        let id: String
        let title: String
        let subtitle: String
        let thumbnailURL: String?
        let tracks: [Video]
    }

    enum State {
        case none, queued, downloaded
    }

    /// A music video counts as saved when its song version is (that is what
    /// a download fetches, see `queue`).
    static func state(of videoId: String) -> State {
        let ids = [videoId] + (MusicSongVersions.songId(of: videoId).map { [$0] } ?? [])
        if ids.contains(where: DownloadStore.isDownloaded) {
            return .downloaded
        }
        return ids.contains(where: VideoDownloader.shared.isQueued) ? .queued : .none
    }

    /// Queues every track not saved yet. Options are asked for one track at
    /// a time: an album is a dozen `/player` calls, not a burst of them.
    static func download(_ tracks: [Video]) {
        let pending = tracks.filter { state(of: $0.id) == .none }
        AppLog.downloads("music: queueing \(pending.count) of \(tracks.count) tracks")
        queue(pending[...])
    }

    static func download(collection: Playlist, tracks: [Video]) {
        save(collection: collection, tracks: tracks)
        download(tracks)
    }

    /// One at a time, each as its song version when it is a music video
    /// that has one (`MusicSongVersions`).
    private static func queue(_ tracks: ArraySlice<Video>) {
        guard let first = tracks.first else {
            return
        }
        MusicSongVersions.resolve(first) { song in
            let track = song ?? first
            if song != nil {
                AppLog.downloads("music: \(first.id) saved as its song version \(track.id)")
            }
            guard !DownloadStore.isDownloaded(track.id), !VideoDownloader.shared.isQueued(track.id) else {
                queue(tracks.dropFirst())
                return
            }
            start(track, then: tracks.dropFirst())
        }
    }

    private static func start(_ track: Video, then rest: ArraySlice<Video>) {
        fetchLyrics(for: track)
        VideoDownloader.shared.audioOnlyOption(for: track.id) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let option):
                    VideoDownloader.shared.start(video: track, option: option) { done in
                        if case .failure(let error) = done {
                            AppLog.downloads("music: \(track.id) failed — \(error)")
                        }
                    }
                case .failure(let error):
                    AppLog.downloads("music: no audio for \(track.id) — \(error)")
                }
                queue(rest)
            }
        }
    }

    /// Fetching is all it takes: found lyrics are cached by video id.
    private static func fetchLyrics(for track: Video) {
        let seconds = (track.duration ?? "").split(separator: ":")
            .compactMap { Int($0) }
            .reduce(0) { $0 * 60 + $1 }
        OPLyrics.fetch(
            forVideoId: track.id,
            title: track.title,
            artist: track.channelName,
            duration: TimeInterval(seconds)
        ) { lyrics in
            AppLog.downloads("music: lyrics for \(track.id): \(lyrics == nil ? "none" : "saved")")
        }
    }

    /// Deletes saved files (and cancels queued ones). Lyrics stay cached —
    /// they are a few kilobytes and come back with the next download.
    static func remove(_ tracks: [Video]) {
        // The track and its song version, whichever was saved.
        for id in tracks.flatMap({ [$0.id] + (MusicSongVersions.songId(of: $0.id).map { [$0] } ?? []) }) {
            if VideoDownloader.shared.isQueued(id) {
                VideoDownloader.shared.cancel(id)
            } else if DownloadStore.isDownloaded(id) {
                DownloadStore.remove(id)
            }
        }
        DownloadStore.announceChange()
        AppLog.downloads("music: removed \(tracks.count) downloads")
    }

    /// The collection's songs go, except those another downloaded album or
    /// playlist still has (removing a playlist took an album's songs with it).
    static func remove(collection: Playlist, tracks: [Video]) {
        let others = savedCollections().filter { $0.id != collection.id }.flatMap(\.tracks)
        let kept = Set(others.flatMap { [$0.id] + (MusicSongVersions.songId(of: $0.id).map { [$0] } ?? []) })
        let own = tracks.filter { track in
            !kept.contains(track.id) && !(MusicSongVersions.songId(of: track.id).map(kept.contains) ?? false)
        }
        if own.count < tracks.count {
            AppLog.downloads("music: \(tracks.count - own.count) songs of \(collection.title) kept for other downloads")
        }
        remove(own)
        let saved = savedCollections().filter { $0.id != collection.id }
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: collectionsKey)
        }
    }

    // MARK: - Downloaded collections

    private static func save(collection: Playlist, tracks: [Video]) {
        var saved = savedCollections().filter { $0.id != collection.id }
        saved.insert(
            SavedCollection(
                id: collection.id,
                title: collection.title,
                subtitle: collection.description,
                thumbnailURL: collection.thumbnailURL,
                tracks: tracks
            ),
            at: 0
        )
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: collectionsKey)
        }
    }

    private static func savedCollections() -> [SavedCollection] {
        guard let data = UserDefaults.standard.data(forKey: collectionsKey) else {
            return []
        }
        return (try? JSONDecoder().decode([SavedCollection].self, from: data)) ?? []
    }

    /// Albums and playlists downloaded, newest first.
    static func collections() -> [Playlist] {
        savedCollections().map {
            Playlist(
                id: $0.id,
                title: $0.title,
                description: $0.subtitle,
                thumbnailURL: $0.thumbnailURL,
                itemCount: $0.tracks.count
            )
        }
    }

    /// The track list saved with a downloaded collection, for offline.
    static func savedTracks(of collectionId: String) -> [Video]? {
        savedCollections().first { $0.id == collectionId }?.tracks
    }

    // MARK: - Keeping playlists downloaded

    private static let syncedKey = "musicDownloads_playlistsSyncedAt"

    /// Albums do not change; playlists do. The app's own lists are not
    /// YouTube's.
    private static func isPlaylist(_ id: String) -> Bool {
        !id.hasPrefix("OLAK5uy") && !id.hasPrefix("MPREb") && !id.hasPrefix("opaline.")
    }

    /// Downloaded playlists keep up: songs added since are downloaded too.
    /// On Wi-Fi only, at most every few hours. Songs taken out of a playlist
    /// leave its offline list but keep their files (still under Downloaded
    /// songs): a download is never deleted behind the user's back.
    private static var resumedAt: TimeInterval = 0

    /// Downloads are queued in memory: an album whose download the app did
    /// not live through (killed, reinstalled) kept its place in Downloads
    /// with songs never saved. On Wi-Fi, at most every half hour, every
    /// downloaded album and playlist gets its missing songs queued again.
    static func resumeIncomplete() {
        let now = Date().timeIntervalSince1970
        guard !NetworkType.isOffline, !NetworkType.isCellular, now - resumedAt > 1_800 else {
            return
        }
        resumedAt = now
        let missing = savedCollections().map { saved in
            (saved, saved.tracks.filter { state(of: $0.id) == .none })
        }.filter { !$0.1.isEmpty }
        guard !missing.isEmpty else {
            return
        }
        AppLog.downloads(
            "music: resuming " + missing.map { "\($0.0.title) (\($0.1.count) of \($0.0.tracks.count))" }
                .joined(separator: ", ")
        )
        var seen = Set<String>()
        download(missing.flatMap(\.1).filter { seen.insert($0.id).inserted })
    }

    /// How many of a downloaded collection's songs are on the device.
    static func savedCount(ofCollection id: String) -> (saved: Int, total: Int) {
        let tracks = savedCollections().first { $0.id == id }?.tracks ?? []
        return (tracks.filter { state(of: $0.id) == .downloaded }.count, tracks.count)
    }

    static func syncPlaylists() {
        guard !NetworkType.isOffline, !NetworkType.isCellular else {
            return
        }
        let now = Date().timeIntervalSince1970
        guard now - UserDefaults.standard.double(forKey: syncedKey) > 6 * 3_600 else {
            return
        }
        let playlists = savedCollections().filter { isPlaylist($0.id) }
        guard !playlists.isEmpty else {
            return
        }
        UserDefaults.standard.set(now, forKey: syncedKey)
        AppLog.downloads("music: checking \(playlists.count) downloaded playlists for new songs")
        sync(playlists[...])
    }

    /// One playlist at a time.
    private static func sync(_ playlists: ArraySlice<SavedCollection>) {
        guard let saved = playlists.first else {
            return
        }
        fetchAllTracks(of: saved.id) { tracks in
            if let tracks, !tracks.isEmpty {
                let known = Set(saved.tracks.map(\.id))
                let added = tracks.filter { !known.contains($0.id) }
                AppLog.downloads(
                    "music: \(saved.title): \(added.count) new, \(tracks.count) in all (was \(saved.tracks.count))"
                )
                if tracks.map(\.id) != saved.tracks.map(\.id) {
                    replaceTracks(of: saved.id, with: tracks)
                }
                download(added)
            }
            sync(playlists.dropFirst())
        }
    }

    /// The whole playlist: YouTube Music's page with the web account, else
    /// the TV client's pages. Nil when it cannot be read.
    private static func fetchAllTracks(of playlistId: String, completion: @escaping ([Video]?) -> Void) {
        YTMusicPublic.playlist(playlistId) { result in
            if let result {
                completion(result.tracks)
                return
            }
            var all: [Video] = []
            func fetch(_ continuation: String?) {
                ServiceContainer.playlists.fetchPlaylistVideos(playlistId: playlistId, continuation: continuation) { result in
                    DispatchQueue.main.async {
                        guard case .success(let page) = result else {
                            completion(all.isEmpty ? nil : all)
                            return
                        }
                        all += page.videos
                        if let next = page.continuation {
                            fetch(next)
                        } else {
                            completion(all)
                        }
                    }
                }
            }
            fetch(nil)
        }
    }

    private static func replaceTracks(of id: String, with tracks: [Video]) {
        let saved = savedCollections().map { collection -> SavedCollection in
            guard collection.id == id else {
                return collection
            }
            return SavedCollection(
                id: collection.id, title: collection.title, subtitle: collection.subtitle,
                thumbnailURL: collection.thumbnailURL, tracks: tracks
            )
        }
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: collectionsKey)
        }
    }

    // MARK: - Storage

    /// Bytes a saved track takes (its folder: audio, artwork, metadata),
    /// counting its song version's when that is what was saved.
    static func size(of videoId: String) -> Int64 {
        let ids = [videoId] + (MusicSongVersions.songId(of: videoId).map { [$0] } ?? [])
        return ids.filter(DownloadStore.isDownloaded).reduce(0) { $0 + folderSize(DownloadStore.folder(for: $1)) }
    }

    /// Saved by music mode (sound only), not a video download kept in the
    /// same store. Reads the file: call off the main thread.
    static func isAudioOnly(_ videoId: String) -> Bool {
        DownloadStore.isDownloaded(videoId)
            && AVURLAsset(url: DownloadStore.videoFile(for: videoId)).tracks(withMediaType: .video).isEmpty
    }

    private static func folderSize(_ folder: URL) -> Int64 {
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let file = files?.nextObject() as? URL {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    /// A downloaded collection's saved tracks.
    static func tracks(ofCollection id: String) -> [Video] {
        savedCollections().first { $0.id == id }?.tracks ?? []
    }

    /// The Library row that opens `MusicStorageViewController`.
    static let storageId = "opaline.storage"

    static var storage: Playlist {
        Playlist(id: storageId, title: "Storage", description: "What downloads take", thumbnailURL: nil, itemCount: nil)
    }

    /// Pseudo-collection listing every downloaded track.
    static let allSongsId = "opaline.downloaded"

    static var allSongs: Playlist {
        Playlist(
            id: allSongsId,
            title: "Downloaded songs",
            description: "On this device",
            thumbnailURL: nil,
            itemCount: nil
        )
    }
}
