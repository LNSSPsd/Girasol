import Foundation

/// One row of the music home feed: a titled shelf of albums, playlists and
/// songs.
struct MusicShelf {
    let title: String
    let items: [MusicItem]
}

enum MusicItem {
    /// An album or playlist, opened as a track list.
    case collection(Playlist)
    /// A single song or video, played directly.
    case track(Video)
}

// MARK: - YouTube Music history

extension InnertubeClient {
    typealias MusicTarget = (host: String, client: [String: Any])

    private static let tvClient: [String: Any] = [
        "clientName": "TVHTML5", "clientVersion": "7.20260311.12.00", "hl": "en", "gl": "US"
    ]

    /// Headers a real client of this kind sends: the client id pair always,
    /// `Origin` for the web clients. The signed-in web attempts used to go
    /// without them, which left "invalid argument" unexplained.
    static func clientHeaders(for client: [String: Any], host: String) -> [String: String] {
        let name = client["clientName"] as? String ?? ""
        let version = client["clientVersion"] as? String ?? ""
        let ids = [
            "WEB": "1", "MWEB": "2", "ANDROID": "3", "IOS": "5", "TVHTML5": "7",
            "WEB_REMIX": "67"
        ]
        var headers: [String: String] = ["X-YouTube-Client-Version": version]
        if let id = ids[name] {
            headers["X-YouTube-Client-Name"] = id
        }
        switch name {
        case "WEB", "MWEB", "WEB_REMIX":
            headers["Origin"] = "https://\(host)"
        default:
            break
        }
        return headers
    }

    /// Recently played tracks, newest first, for Listen again. The TV client
    /// on the YouTube Music host is the pairing that answers the TV sign-in
    /// for library data; `FEmusic_home` is refused to every web/TV client, and
    /// the YT Music apps' token is unreachable.
    func fetchMusicHistory(
        completion: @escaping (Result<[Video], Error>) -> Void
    ) {
        withValidToken(completion: completion) { client, token in
            client.musicBrowse(
                browseId: "FEmusic_history",
                targets: [
                    ("music.youtube.com", Self.tvClient),
                    ("www.youtube.com", Self.tvClient)
                ],
                token: token,
                parse: { json -> [Video]? in
                    var seen = Set<String>()
                    let tracks = Self.musicShelves(in: json)
                        .flatMap(\.items)
                        .compactMap { item -> Video? in
                            guard case .track(let video) = item else {
                                return nil
                            }
                            return video
                        }
                        .filter { seen.insert($0.id).inserted }
                    return tracks.isEmpty ? nil : tracks
                },
                completion: completion
            )
        }
    }

    /// Posts `browseId` to each target in turn; the first response `parse`
    /// accepts wins. Every attempt is logged with its status, so a refusal
    /// shows up with YouTube's reason.
    func musicBrowse<T>(
        browseId: String,
        targets: [MusicTarget],
        token: String,
        attempt: Int = 0,
        parse: @escaping ([String: Any]) -> T?,
        completion: @escaping (Result<T, Error>) -> Void
    ) {
        musicPost(
            endpoint: "browse", fields: ["browseId": browseId], tag: browseId,
            targets: targets, token: token, attempt: attempt, parse: parse, completion: completion
        )
    }

    /// Posts `fields` to `endpoint` on each target in turn; the first
    /// response `parse` accepts wins, every refusal is logged with its body.
    func musicPost<T>(
        endpoint: String,
        fields: [String: Any],
        tag label: String,
        targets: [MusicTarget],
        token: String,
        attempt: Int = 0,
        parse: @escaping ([String: Any]) -> T?,
        completion: @escaping (Result<T, Error>) -> Void
    ) {
        guard attempt < targets.count,
              let url = URL(
                  string: "https://\(targets[attempt].host)/youtubei/v1/\(endpoint)?prettyPrint=false"
              )
        else {
            completion(.failure(APIError.invalidResponse))
            return
        }
        let target = targets[attempt]
        let tag = "music(\(label))[\(target.host) \(target.client["clientName"] ?? "")]"
        var body = fields
        body["context"] = ["client": target.client]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        for (field, value) in Self.clientHeaders(for: target.client, host: target.host) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let next = {
                self?.musicPost(
                    endpoint: endpoint, fields: fields, tag: label, targets: targets, token: token,
                    attempt: attempt + 1, parse: parse, completion: completion
                )
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard error == nil, status == 200, let data,
                  let json = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any]
            else {
                let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                AppLog.innertube(
                    "\(tag): failed status=\(status) error=\(String(describing: error))"
                        + " sent=\(fields.keys.sorted()) body=\(text.prefix(400))"
                )
                next()
                return
            }
            guard let result = parse(json) else {
                AppLog.innertube(
                    "\(tag): nothing parsed, response:\n"
                        + AppLog.shape(of: json, maxDepth: 14).prefix(10_000)
                )
                next()
                return
            }
            AppLog.innertube("\(tag): ok")
            completion(.success(result))
        }.resume()
    }

    // MARK: - Parsing

    private static let shelfKeys = [
        "musicCarouselShelfRenderer", "musicImmersiveCarouselShelfRenderer",
        "musicShelfRenderer", "shelfRenderer", "gridRenderer"
    ]

    /// Every shelf in the response, in order, whichever renderer it uses.
    static func musicShelves(in value: Any) -> [MusicShelf] {
        if let array = value as? [Any] {
            return array.flatMap { musicShelves(in: $0) }
        }
        guard let dict = value as? [String: Any] else {
            return []
        }
        for key in shelfKeys {
            if let shelf = dict[key] as? [String: Any] {
                let items = shelfItems(shelf).compactMap(musicItem)
                guard !items.isEmpty else {
                    return []
                }
                let title = firstText(in: shelf["header"] as Any, key: "title")
                    ?? simpleText(from: shelf["title"])
                    ?? texts(in: shelf["title"] as Any).joined()
                return [MusicShelf(title: title, items: items)]
            }
        }
        return dict.keys.sorted().flatMap { musicShelves(in: dict[$0] as Any) }
    }

    private static func shelfItems(_ shelf: [String: Any]) -> [[String: Any]] {
        let list = shelf["contents"] as? [Any]
            ?? shelf["items"] as? [Any]
            ?? shelf.digDict("content", "horizontalListRenderer")?["items"] as? [Any]
            ?? shelf.digDict("content", "gridRenderer")?["items"] as? [Any]
            ?? []
        // Each entry wraps exactly one renderer.
        return list.compactMap { ($0 as? [String: Any])?.values.first as? [String: Any] }
    }

    /// A song when the item's own action plays a video; an album or playlist
    /// when it opens a browse page and carries a playable playlist id.
    /// Anything else (artists, moods) has no place in a track list.
    static func musicItem(_ renderer: [String: Any]) -> MusicItem? {
        let action = renderer["navigationEndpoint"] as? [String: Any]
            ?? renderer["onSelectCommand"] as? [String: Any]
            ?? renderer.digDict("overlay", "musicItemThumbnailOverlayRenderer", "content",
                                "musicPlayButtonRenderer", "playNavigationEndpoint")
        let title = simpleText(from: renderer["title"])
            ?? simpleText(from: renderer.digDict("metadata", "tileMetadataRenderer")?["title"])
            ?? firstText(in: renderer["flexColumns"] as Any, key: "text")
            ?? ""
        let subtitle = renderer["subtitle"] != nil
            ? texts(in: renderer["subtitle"] as Any).joined()
            : tileLines(renderer.digDict("metadata", "tileMetadataRenderer"))
        let thumbnail = lastThumbnailURL(in: renderer["thumbnailRenderer"] as Any)
            ?? lastThumbnailURL(in: renderer["thumbnail"] as Any)
            ?? lastThumbnailURL(in: renderer["header"] as Any)
        if let videoId = (action?["watchEndpoint"] as? [String: Any])?["videoId"] as? String {
            return .track(Video(
                id: videoId,
                title: title,
                channelId: nil,
                channelName: subtitle,
                channelAvatarURL: nil,
                thumbnailURL: thumbnail
                    ?? "https://i.ytimg.com/vi/\(videoId)/hqdefault.jpg",
                viewCount: nil,
                publishedAt: nil,
                duration: nil
            ))
        }
        guard let browseId = (action?["browseEndpoint"] as? [String: Any])?["browseId"]
                as? String
        else {
            return nil
        }
        let playlistId = browseId.hasPrefix("VL")
            ? String(browseId.dropFirst(2))
            : firstPlaylistId(in: renderer)
        guard let playlistId, !playlistId.isEmpty else {
            return nil
        }
        return .collection(Playlist(
            id: playlistId,
            title: title,
            description: subtitle,
            thumbnailURL: thumbnail,
            itemCount: nil
        ))
    }

    static func lastThumbnailURL(in value: Any) -> String? {
        if let dict = value as? [String: Any] {
            if let thumbs = dict["thumbnails"] as? [[String: Any]],
               let url = thumbs.last?["url"] as? String {
                return url.hasPrefix("//") ? "https:" + url : url
            }
            return dict.keys.sorted().lazy
                .compactMap { lastThumbnailURL(in: dict[$0] as Any) }.first
        }
        if let array = value as? [Any] {
            return array.lazy.compactMap { lastThumbnailURL(in: $0) }.first
        }
        return nil
    }
}

// MARK: - Library artists

extension InnertubeClient {
    /// The artists in the YouTube Music library, through the TV sign-in like
    /// the album and playlist shelves.
    func fetchLibraryArtists(completion: @escaping (Result<[MusicArtistRef], Error>) -> Void) {
        let tv: [String: Any] = [
            "clientName": "TVHTML5", "clientVersion": "7.20260311.12.00", "hl": "en", "gl": "US"
        ]
        withValidToken(completion: completion) { client, token in
            client.musicBrowse(
                browseId: "FEmusic_library_corpus_artists",
                targets: [("music.youtube.com", tv), ("www.youtube.com", tv)],
                token: token,
                parse: { json -> [MusicArtistRef]? in
                    var seen = Set<String>()
                    let artists = Self.artistTiles(in: json).filter { seen.insert($0.browseId).inserted }
                    return artists.isEmpty ? nil : artists
                },
                completion: completion
            )
        }
    }

    /// Tiles that open a channel (`UC…`): the TV shape of an artist.
    static func artistTiles(in value: Any) -> [MusicArtistRef] {
        if let array = value as? [Any] {
            return array.flatMap { artistTiles(in: $0) }
        }
        guard let dict = value as? [String: Any] else {
            return []
        }
        if let tile = dict["tileRenderer"] as? [String: Any] {
            guard let id = tile.digString("onSelectCommand", "browseEndpoint", "browseId"),
                  id.hasPrefix("UC")
            else {
                return []
            }
            let meta = tile.digDict("metadata", "tileMetadataRenderer")
            return [MusicArtistRef(
                browseId: id,
                name: simpleText(from: meta?["title"]) ?? "",
                subtitle: tileLines(meta),
                thumbnailURL: lastThumbnailURL(in: tile["header"] as Any)
            )]
        }
        return dict.keys.sorted().flatMap { artistTiles(in: dict[$0] as Any) }
    }
}
