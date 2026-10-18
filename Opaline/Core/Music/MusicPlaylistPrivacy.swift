// SPDX-License-Identifier: CC0-1.0
import Foundation

/// Who can see each of the user's playlists, shown in Library and on the
/// playlist's page. Neither sign-in's playlist lists say it; youtube.com's
/// own page of the playlist, read signed out, does
/// (`YTMusicPublic.playlistPrivacy`). Kept in UserDefaults, set at once by
/// the app's own changes, and asked again when older than `maxAge`.
enum MusicPlaylistPrivacy {
    /// Posted when a playlist's privacy is learned or changed.
    static let didChangeNotification = Notification.Name("MusicPlaylistPrivacyDidChange")

    private static let key = "musicPlaylistPrivacy"
    private static let maxAge: TimeInterval = 6 * 3600
    private static var asking: Set<String> = []

    private static var stored: [String: [String: Any]] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: [String: Any]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Only real playlists have a privacy of their own (not Liked songs,
    /// albums, Watch later or the app's own lists).
    static func applies(to playlistId: String) -> Bool {
        playlistId.hasPrefix("PL")
    }

    static func known(_ playlistId: String) -> PlaylistPrivacy? {
        (stored[playlistId]?["privacy"] as? String).flatMap(PlaylistPrivacy.init(rawValue:))
    }

    /// The app just set it (created, edited).
    static func note(_ playlistId: String, _ privacy: PlaylistPrivacy) {
        guard applies(to: playlistId) else {
            return
        }
        stored[playlistId] = ["privacy": privacy.rawValue, "at": Date().timeIntervalSince1970]
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    /// Asks youtube.com about the ones not known lately (`force`: every
    /// one), two at a time. Main queue.
    static func refresh(_ playlistIds: [String], force: Bool = false) {
        let now = Date().timeIntervalSince1970
        let due = playlistIds.filter { id in
            guard applies(to: id), !asking.contains(id) else {
                return false
            }
            let at = stored[id]?["at"] as? TimeInterval ?? 0
            return force || now - at > maxAge
        }
        asking.formUnion(due)
        var left = due[...]
        func next() {
            guard let id = left.popFirst() else {
                return
            }
            YTMusicPublic.playlistPrivacy(id) { privacy in
                DispatchQueue.main.async {
                    asking.remove(id)
                    if let privacy {
                        let changed = known(id) != privacy
                        stored[id] = ["privacy": privacy.rawValue, "at": Date().timeIntervalSince1970]
                        if changed {
                            AppLog.innertube("playlist \(id) is \(privacy.rawValue)")
                            NotificationCenter.default.post(name: didChangeNotification, object: nil)
                        }
                    }
                    next()
                }
            }
        }
        next()
        next()
    }
}

extension PlaylistPrivacy {
    /// For subtitles: "Public", "Link only", "Private".
    var shortTitle: String {
        switch self {
        case .publicList:
            return "Public"
        case .unlisted:
            return "Link only"
        case .privateList:
            return "Private"
        }
    }
}
