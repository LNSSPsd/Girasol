import Foundation

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

    static func remove(collection: Playlist, tracks: [Video]) {
        remove(tracks)
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
