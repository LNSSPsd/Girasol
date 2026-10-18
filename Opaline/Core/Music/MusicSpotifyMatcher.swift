// SPDX-License-Identifier: CC0-1.0
import Foundation

/// Finds a Spotify track's song on YouTube Music, through its song search
/// (signed out). No match beats a wrong one:
///
/// - The title, without its version and credits ("- 2024 Remaster",
///   "(feat. …)", "(From …)"), must be the same, one of the artists must be
///   credited on both, and the lengths within 3 s: the same recording.
///   A re-recording under the same title passes the title and fails the
///   length, which is right — it is not the recording YouTube Music has.
/// - Japanese titles and artists are asked in Japanese too: in English,
///   YouTube Music romanizes Japanese artists and adds a romanized
///   title ("<original> - <romaji>"); Spotify keeps the original.
/// - A title written another way (in katakana on one side and in
///   Latin letters on the other) counts only as the search's top
///   song, by a credited artist, within 3 s, with no other song of that
///   artist in the results within 5 s of it.
enum MusicSpotifyMatcher {
    /// Found this launch, by Spotify track id (`nil` = searched, none).
    private static var found: [String: Video?] = [:]

    /// Main queue.
    static func match(_ track: OPSpotifyTrack, completion: @escaping (Video?) -> Void) {
        if let known = found[track.trackId] {
            completion(known)
            return
        }
        let query = searchText("\(track.title) \(track.artists.first ?? "")")
        let japanese = YTMusicPublic.hasJapanese(track.title + track.artists.joined())
        let languages = japanese ? ["en", "ja"] : ["en"]
        var answers: [String: [YTMusicPublic.SongCandidate]] = [:]
        for hl in languages {
            YTMusicPublic.songCandidates(query, hl: hl) { candidates in
                answers[hl] = candidates
                guard answers.count == languages.count else {
                    return
                }
                let lists = languages.compactMap { answers[$0] }
                let video = best(for: track, in: lists)
                // The English entry when both have it: it is the one the
                // rest of music mode is built from.
                let shown = video.flatMap { pick in
                    answers["en"]?.first { $0.video.id == pick.id }?.video ?? pick
                }
                AppLog.player(
                    "spotify \(track.trackId) \"\(track.title)\" by \(track.artists.joined(separator: ", ")):"
                        + " \(shown.map { "\($0.id) \"\($0.title)\"" } ?? "no match")"
                )
                found[track.trackId] = .some(shown)
                completion(shown)
            }
        }
    }

    /// Every track, four searches at a time, `each` as they come.
    static func matchAll(
        _ tracks: [OPSpotifyTrack],
        each: @escaping (Int, Video?) -> Void,
        done: @escaping () -> Void
    ) {
        var next = 0
        var running = 0
        func start() {
            while running < 4, next < tracks.count {
                let index = next
                next += 1
                running += 1
                match(tracks[index]) { video in
                    running -= 1
                    each(index, video)
                    if next >= tracks.count, running == 0 {
                        done()
                    } else {
                        start()
                    }
                }
            }
        }
        guard !tracks.isEmpty else {
            done()
            return
        }
        start()
    }

    private static func best(
        for track: OPSpotifyTrack,
        in lists: [[YTMusicPublic.SongCandidate]]
    ) -> Video? {
        let length = Int(track.duration.rounded())
        let artists = Set(track.artists.map(normalized))
        let byArtist = { (candidate: YTMusicPublic.SongCandidate) -> Bool in
            let names = candidate.artists + [candidate.video.musicArtist]
            return !artists.isDisjoint(with: names.map(normalized))
        }
        let gap = { (candidate: YTMusicPublic.SongCandidate) -> Int in
            candidate.seconds.map { abs($0 - length) } ?? .max
        }
        let title = core(track.title)
        let full = normalized(track.title)
        let same = lists.joined().filter {
            !title.isEmpty && core($0.title) == title && byArtist($0) && gap($0) <= 3
        }
        // The same version first ("(2024 Remaster)" against the original),
        // then the closest length.
        if let pick = same.min(by: { lhs, rhs in
            let lhsExact = normalized(lhs.title) == full
            let rhsExact = normalized(rhs.title) == full
            return lhsExact != rhsExact ? lhsExact : gap(lhs) < gap(rhs)
        }) {
            return pick.video
        }
        for list in lists {
            guard let top = list.first, byArtist(top), gap(top) <= 3 else {
                continue
            }
            let rivals = list.dropFirst().filter { $0.video.id != top.video.id && byArtist($0) && gap($0) <= 5 }
            if rivals.isEmpty {
                return top.video
            }
        }
        return nil
    }

    /// YouTube's search reads "-word" as "without word" ("Song -live-"
    /// finds nothing), so hyphens go.
    private static func searchText(_ text: String) -> String {
        text.replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Case and width folded, apostrophes dropped (YouTube Music writes
    /// "It's" as "Its" too), other punctuation as spaces. Not diacritics:
    /// they would make ジ and シ the same letter.
    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "['’ʼ`]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// The song's name alone: no credits, no " - version", no brackets.
    private static func core(_ title: String) -> String {
        var text = title.replacingOccurrences(
            of: "\\s*[\\(\\[（](feat\\.?|ft\\.|featuring|with)\\s[^\\)\\]）]*[\\)\\]）]|\\s+(feat\\.?|ft\\.)\\s.*$",
            with: "", options: [.regularExpression, .caseInsensitive]
        )
        if let dash = text.range(of: " - ") {
            text = String(text[..<dash.lowerBound])
        }
        text = text.replacingOccurrences(
            of: "\\s*[\\(\\[（【][^\\)\\]）】]*[\\)\\]）】]", with: "", options: .regularExpression
        )
        return normalized(text)
    }
}
