// SPDX-License-Identifier: CC0-1.0
import Foundation

/// YouTube's own "this is music" mark: watch links to music carry a
/// `musicVideoType` (OMV official video, ATV album track, UGC cover, …),
/// ordinary videos none. Noted for every tile parsed anywhere, so music
/// mode can tell songs from a cooking video in the watch history.
enum MusicVideoTypes {
    private static let lock = NSLock()
    private static var types: [String: String] = [:]

    static func record(videoId: String, in tile: [String: Any]) {
        guard let type = tile.digString(
            "onSelectCommand", "watchEndpoint", "watchEndpointMusicSupportedConfigs",
            "watchEndpointMusicConfig", "musicVideoType"
        ) else {
            return
        }
        lock.lock()
        types[videoId] = type
        lock.unlock()
    }

    static func type(of videoId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return types[videoId]
    }
}
