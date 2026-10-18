// SPDX-License-Identifier: CC0-1.0
import Foundation

/// Listen again, built the way YouTube Music describes it: songs you play
/// often, brought back once you have not played them for a while. Inputs:
/// music mode's own play log, plus YouTube Music's history with the web
/// account, else the TV sign-in's YouTube watch history (refused YouTube
/// Music's; it still holds older music plays — music mode no longer
/// reports there).
enum MusicListenAgain {
    private static let historyPages = 5
    private static let resultCount = 20

    static func load(completion: @escaping ([Video]) -> Void) {
        YTMusicPublic.history { songs in
            guard let songs else {
                loadWatchHistory(completion: completion)
                return
            }
            completion(rank(history: songs, allMusic: true))
        }
    }

    private static func loadWatchHistory(completion: @escaping ([Video]) -> Void) {
        ServiceContainer.history.fetchHistory { result in
            guard case .success(let first) = result else {
                DispatchQueue.main.async {
                    completion(rank(history: []))
                }
                return
            }
            loadMore(collected: first.videos, continuation: first.continuation, pagesLeft: historyPages - 1) {
                let ranked = rank(history: $0)
                DispatchQueue.main.async {
                    completion(ranked)
                }
            }
        }
    }

    /// More pages mean more repeat plays to count.
    private static func loadMore(
        collected: [Video],
        continuation: String?,
        pagesLeft: Int,
        done: @escaping ([Video]) -> Void
    ) {
        guard pagesLeft > 0, let continuation else {
            done(collected)
            return
        }
        OAuthClient.shared.validToken { token in
            guard case .success(let token) = token else {
                done(collected)
                return
            }
            ServiceContainer.history.fetchHistoryNextPage(
                continuation: continuation, token: token
            ) { result in
                guard case .success(let page) = result else {
                    done(collected)
                    return
                }
                loadMore(
                    collected: collected + page.videos,
                    continuation: page.continuation,
                    pagesLeft: pagesLeft - 1,
                    done: done
                )
            }
        }
    }

    /// Score = how often played × how long since. The history carries no
    /// dates, only order, so its position stands in for time; the play log
    /// has real dates.
    static func rank(history: [Video], allMusic: Bool = false) -> [Video] {
        struct Stat {
            var video: Video
            var plays = 0.0
            /// 0 = just played, 1 = as long ago as anything we know of.
            var staleness = 1.0
        }
        var stats: [String: Stat] = [:]
        // YouTube's music mark decides; the length guess is only the fallback
        // for a history that carries no marks at all.
        let marked = allMusic ? history : history.filter { MusicVideoTypes.type(of: $0.id) != nil }
        let songs = marked.isEmpty ? history.filter(looksLikeSong) : marked
        AppLog.player(
            "listen again: \(marked.count) of \(history.count) history entries marked music"
                + (marked.isEmpty ? " — none, falling back to length" : "")
                + "; left out: "
                + history.filter { MusicVideoTypes.type(of: $0.id) == nil }
                    .prefix(5).map(\.title).joined(separator: " | ")
        )
        let count = Double(max(songs.count, 1))
        for (position, video) in songs.enumerated() {
            var stat = stats[video.id] ?? Stat(video: video)
            stat.plays += 1
            stat.staleness = min(stat.staleness, Double(position) / count)
            stats[video.id] = stat
        }
        let now = Date()
        for (video, plays) in MusicPlayLog.shared.trackPlays() {
            guard let last = plays.max() else {
                continue
            }
            var stat = stats[video.id] ?? Stat(video: video)
            stat.plays += Double(plays.count)
            // Two weeks without a play counts as fully stale.
            let days = now.timeIntervalSince(last) / 86_400
            stat.staleness = min(stat.staleness, min(days / 14, 1))
            stats[video.id] = stat
        }
        func score(_ stat: Stat) -> Double {
            // Repeat plays count most. Among equals, recent beats old — a
            // history of mostly single plays must not surface its tail —
            // except the last few plays, which are not "again" yet.
            let recency = stat.staleness < 0.03 ? 0.35 : 1.0 - 0.7 * stat.staleness
            return log(1 + stat.plays) * recency
        }
        let ranked = stats.values.sorted { score($0) > score($1) }
        AppLog.player(
            "listen again: \(songs.count) history songs, \(stats.count) candidates; top: "
                + ranked.prefix(5).map { "\($0.video.title) (\(Int($0.plays))×, \(String(format: "%.2f", $0.staleness)))" }
                    .joined(separator: ", ")
        )
        return ranked.prefix(resultCount).map(\.video)
    }

    /// The history has no "is music" flag: skip Shorts, live streams and
    /// anything longer than a long song.
    static func looksLikeSong(_ video: Video) -> Bool {
        guard !video.isShort, !video.isLive, let duration = video.duration else {
            return false
        }
        let seconds = duration.split(separator: ":")
            .compactMap { Int($0) }
            .reduce(0) { $0 * 60 + $1 }
        return seconds > 0 && seconds <= 12 * 60
    }
}
