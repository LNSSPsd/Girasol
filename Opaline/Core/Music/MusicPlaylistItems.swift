import Foundation

/// Playlist entry ids (`setVideoId`): YouTube moves and removes playlist
/// entries by these, not by video id. Collected from any playlist page that
/// carries them; for a playlist whose signed-in page does not, YouTube
/// Music's public page of it does (public and unlisted playlists).
enum MusicPlaylistItems {
    private static let lock = NSLock()
    private static var ids: [String: [String: String]] = [:]

    static func setVideoId(of videoId: String, in playlistId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return ids[playlistId]?[videoId]
    }

    /// Scans page items for a video id with its entry id beside it.
    static func collect(playlistId: String, from contents: Any) {
        var found: [String: String] = [:]
        scan(contents, into: &found)
        guard !found.isEmpty else {
            return
        }
        lock.lock()
        ids[playlistId, default: [:]].merge(found) { $1 }
        lock.unlock()
    }

    private static func scan(_ value: Any, into found: inout [String: String]) {
        if let array = value as? [Any] {
            for element in array {
                scan(element, into: &found)
            }
            return
        }
        guard let dict = value as? [String: Any] else {
            return
        }
        // Wherever a setVideoId sits next to a videoId (playlistItemData,
        // playlist edit endpoints, menu removal actions).
        let entry = dict["setVideoId"] as? String ?? dict["playlistSetVideoId"] as? String
        let video = dict["videoId"] as? String ?? dict["removedVideoId"] as? String
        if let entry, let video {
            found[video] = entry
        }
        for child in dict.values {
            scan(child, into: &found)
        }
    }

    /// Fills in from YouTube Music's public page of the playlist.
    static func loadPublic(playlistId: String, completion: @escaping () -> Void) {
        YTMusicPublic.playlistEntries(playlistId) { contents in
            if let contents {
                collect(playlistId: playlistId, from: contents)
            }
            completion()
        }
    }

    /// Edit actions turning `old` into `new` (same tracks, other order):
    /// each step moves the track that belongs at a position in front of the
    /// one sitting there. Nil when an entry id is missing.
    static func moveActions(from old: [Video], to new: [Video], in playlistId: String) -> [[String: Any]]? {
        var order = old.map(\.id)
        var actions: [[String: Any]] = []
        for (position, track) in new.enumerated() where order[position] != track.id {
            guard let moved = setVideoId(of: track.id, in: playlistId),
                  let successor = setVideoId(of: order[position], in: playlistId),
                  let from = order.firstIndex(of: track.id)
            else {
                return nil
            }
            actions.append([
                "action": "ACTION_MOVE_VIDEO_BEFORE",
                "setVideoId": moved,
                "movedSetVideoIdSuccessor": successor
            ])
            order.remove(at: from)
            order.insert(track.id, at: position)
        }
        return actions
    }

    /// Each row's entry id when the page that listed them did not carry
    /// one: the remembered id, but only for a video that is in the list
    /// once — a duplicate's copies cannot be told apart by video id.
    static func entryIds(for tracks: [Video], in playlistId: String) -> [String?] {
        let counts = Dictionary(tracks.map { ($0.id, 1) }, uniquingKeysWith: +)
        return tracks.map { counts[$0.id] == 1 ? setVideoId(of: $0.id, in: playlistId) : nil }
    }

    /// Edit actions turning one order of entries into another (entry ids,
    /// so duplicates move as themselves). Nil when an id is missing.
    static func moveActions(fromEntries old: [String?], to new: [String?]) -> [[String: Any]]? {
        guard !old.contains(where: { $0 == nil }), !new.contains(where: { $0 == nil }) else {
            return nil
        }
        var order = old.compactMap { $0 }
        var actions: [[String: Any]] = []
        for (position, moved) in new.compactMap({ $0 }).enumerated() where order[position] != moved {
            guard let from = order.firstIndex(of: moved) else {
                return nil
            }
            actions.append([
                "action": "ACTION_MOVE_VIDEO_BEFORE",
                "setVideoId": moved,
                "movedSetVideoIdSuccessor": order[position]
            ])
            order.remove(at: from)
            order.insert(moved, at: position)
        }
        return actions
    }

    /// The action removing one row: by its entry id, else by video id when
    /// the video is in the playlist only once. Nil when that cannot be told.
    static func removeAction(videoId: String, entryId: String?, unique: Bool) -> [String: Any]? {
        if let entryId {
            return ["action": "ACTION_REMOVE_VIDEO", "setVideoId": entryId]
        }
        return unique ? ["action": "ACTION_REMOVE_VIDEO_BY_VIDEO_ID", "removedVideoId": videoId] : nil
    }
}
