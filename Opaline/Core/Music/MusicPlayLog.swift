// SPDX-License-Identifier: CC0-1.0
import Foundation

/// What music mode has played, kept on the device: the albums and playlists
/// started and the tracks heard. Speed dial ranks collections from it the way
/// YouTube Music does — often and lately played first.
final class MusicPlayLog {
    static let shared = MusicPlayLog()

    private struct Entry: Codable {
        let id: String
        let title: String
        let subtitle: String
        let thumbnailURL: String?
        var plays: [Date]
    }

    private struct TrackEntry: Codable {
        let video: Video
        var plays: [Date]
    }

    private static let key = "musicPlayLog_collections"
    private static let tracksKey = "musicPlayLog_tracks"
    private var tracks: [String: TrackEntry] = [:]
    /// Plays older than this no longer count.
    private static let window: TimeInterval = 90 * 24 * 3_600
    /// A play loses half its weight every two weeks.
    private static let halfLife: TimeInterval = 14 * 24 * 3_600

    private var entries: [String: Entry] = [:]
    /// Encoding every track heard and storing it is not main-thread work: it
    /// ran at every song start. One queue keeps the writes in order.
    private let writer = DispatchQueue(label: "MusicPlayLog.writer", qos: .utility)

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let stored = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = stored
        }
        if let data = UserDefaults.standard.data(forKey: Self.tracksKey),
           let stored = try? JSONDecoder().decode([String: TrackEntry].self, from: data) {
            tracks = stored
        }
    }

    func recordCollection(_ collection: Playlist) {
        let now = Date()
        var entry = entries[collection.id] ?? Entry(
            id: collection.id,
            title: collection.title,
            subtitle: collection.description,
            thumbnailURL: collection.thumbnailURL,
            plays: []
        )
        entry.plays = entry.plays.filter { now.timeIntervalSince($0) < Self.window } + [now]
        entries[collection.id] = entry
        save()
    }

    /// Drops a collection from Speed dial (a deleted playlist).
    func forgetCollection(_ id: String) {
        guard entries.removeValue(forKey: id) != nil else {
            return
        }
        save()
    }

    func recordTrack(_ video: Video) {
        let now = Date()
        var entry = tracks[video.id] ?? TrackEntry(video: video, plays: [])
        entry.plays = entry.plays.filter { now.timeIntervalSince($0) < Self.window } + [now]
        tracks[video.id] = entry
        // Tracks not heard within the window count for nothing any more.
        tracks = tracks.filter { $0.value.plays.contains { now.timeIntervalSince($0) < Self.window } }
        let snapshot = tracks
        writer.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                UserDefaults.standard.set(data, forKey: Self.tracksKey)
            }
        }
    }

    /// Tracks played in music mode, with when.
    func trackPlays() -> [(video: Video, plays: [Date])] {
        tracks.values.map { ($0.video, $0.plays) }
    }

    /// Collections by recency-weighted play count, best first.
    func speedDial(limit: Int = 12) -> [Playlist] {
        let now = Date()
        func score(_ entry: Entry) -> Double {
            entry.plays.reduce(0) { total, date in
                total + pow(0.5, now.timeIntervalSince(date) / Self.halfLife)
            }
        }
        return entries.values
            .filter { !$0.plays.isEmpty }
            .sorted { score($0) > score($1) }
            .prefix(limit)
            .map {
                Playlist(
                    id: $0.id,
                    title: $0.title,
                    description: $0.subtitle,
                    thumbnailURL: $0.thumbnailURL,
                    itemCount: nil
                )
            }
    }

    private func save() {
        let snapshot = entries
        writer.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                UserDefaults.standard.set(data, forKey: Self.key)
            }
        }
    }
}
