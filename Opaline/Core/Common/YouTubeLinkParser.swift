import Foundation

/// Pure `URL` → video-id extraction. No networking, no app dependencies —
/// used by `AppDelegate`'s `application(_:open:options:)` and mirrored by
/// `scripts/check_youtube_link_parser.swift` for a runnable check.
enum YouTubeLinkParser {
    /// Path prefixes that carry the video id as the next path component,
    /// e.g. `/shorts/VIDEOID`.
    private static let idPathKeywords: Set<String> = ["shorts", "live", "embed"]

    /// The app's own link scheme, `girasol://`; `ytlite://` is what links
    /// made before the rename (and Opaline's) use, still read the same way.
    static func isAppLink(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "girasol" || scheme == "ytlite"
    }

    static func videoId(from url: URL) -> String? {
        guard let host = url.host?.lowercased() else {
            return nil
        }
        if isAppLink(url) {
            // girasol://watch?v=VIDEOID — host is "watch" for this shape.
            return queryValue(url, name: "v")
        }
        guard isYouTubeHost(host) else {
            return nil
        }
        if host == "youtu.be" {
            return pathComponents(url).first
        }
        let components = pathComponents(url)
        if let keyword = components.first, idPathKeywords.contains(keyword) {
            return components.count > 1 ? components[1] : nil
        }
        if url.path.isEmpty || url.path == "/watch" {
            return queryValue(url, name: "v")
        }
        return nil
    }

    /// A mix is a queue YouTube builds around one video, and its id is `RD`
    /// followed by that video's id. It has no playlist page — asking browse
    /// for `VL` + a mix id answers 400 — so a mix link opens the player with
    /// the mix as its queue, which is what the official app does.
    static func mixSeedVideoId(from url: URL) -> String? {
        guard let list = playlistId(from: url), list.hasPrefix("RD") else {
            return nil
        }
        let seed = String(list.dropFirst(2))
        return seed.count == 11 ? seed : nil
    }

    /// Whether this link is one the app can open at all.
    static func handles(_ url: URL) -> Bool {
        videoId(from: url) != nil || playlistId(from: url) != nil || spotifyPlaylistId(from: url) != nil
    }

    /// A shared Spotify playlist — `open.spotify.com/playlist/ID` (an
    /// `intl-xx/` prefix too), `spotify:playlist:ID`, or
    /// `girasol://spotify?playlist=ID` — which music mode opens to play or
    /// import.
    static func spotifyPlaylistId(from url: URL) -> String? {
        let scheme = url.scheme?.lowercased()
        let id: String?
        if isAppLink(url) {
            id = url.host?.lowercased() == "spotify" ? queryValue(url, name: "playlist") : nil
        } else if scheme == "spotify" {
            let parts = url.absoluteString.split(separator: ":").map(String.init)
            id = parts.count == 3 && parts[1] == "playlist" ? parts[2] : nil
        } else if let host = url.host?.lowercased(), host == "open.spotify.com" || host == "play.spotify.com" {
            let components = pathComponents(url)
            id = components.firstIndex(of: "playlist").flatMap {
                components.indices.contains($0 + 1) ? components[$0 + 1] : nil
            }
        } else {
            id = nil
        }
        guard let id, !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            return nil
        }
        return id
    }

    /// The playlist a link points at — the `list` of a `/playlist` page, or
    /// the one a watch link carries alongside the video.
    static func playlistId(from url: URL) -> String? {
        guard isAppLink(url)
            || (url.host.map { isYouTubeHost($0.lowercased()) } ?? false)
        else {
            return nil
        }
        return queryValue(url, name: "list")
    }

    /// Whether the link points at a short — `/shorts/ID`, or the `shorts=1`
    /// a `girasol://` link carries it over with. The watch screen and the
    /// vertical feed are different destinations, so the shape of the original
    /// link has to survive the trip through the deep link.
    static func isShort(_ url: URL) -> Bool {
        if pathComponents(url).first == "shorts" {
            return true
        }
        return queryValue(url, name: "shorts") == "1"
    }

    /// Seconds a link asks playback to start at — `?t=87`, `?t=1m30s`, or the
    /// `start=` an embed carries. Nil when the link has no timecode.
    static func startSeconds(from url: URL) -> Double? {
        guard let raw = queryValue(url, name: "t")
            ?? queryValue(url, name: "start")
        else {
            return nil
        }
        if let plain = Double(raw) {
            return plain > 0 ? plain : nil
        }
        return unitTimecodeSeconds(raw)
    }

    /// `1h2m3s` and its shorter forms, the shape YouTube's own share sheet
    /// writes for anything past a minute.
    private static func unitTimecodeSeconds(_ raw: String) -> Double? {
        let units: [Character: Double] = ["h": 3_600, "m": 60, "s": 1]
        var total = 0.0
        var digits = ""
        for character in raw.lowercased() {
            if character.isNumber {
                digits.append(character)
                continue
            }
            guard let unit = units[character], let value = Double(digits) else {
                return nil
            }
            total += value * unit
            digits = ""
        }
        guard digits.isEmpty, total > 0 else {
            return nil
        }
        return total
    }

    private static func isYouTubeHost(_ host: String) -> Bool {
        host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com")
    }

    private static func pathComponents(_ url: URL) -> [String] {
        url.pathComponents.filter { $0 != "/" }
    }

    private static func queryValue(_ url: URL, name: String) -> String? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems
        else {
            return nil
        }
        return items.first { $0.name == name }?.value
    }
}
