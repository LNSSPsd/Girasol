import Foundation

// MARK: - YouTube Music library
//
// The TV library lists only the albums saved through YouTube itself; the ones
// liked in YouTube Music live in its own library, which the Music tab reads.

extension InnertubeClient {
    /// One YouTube Music library shelf — `FEmusic_liked_albums`,
    /// `FEmusic_liked_playlists` — as playlists the TV client can open.
    func fetchMusicCollection(
        browseId: String,
        completion: @escaping (Result<[Playlist], Error>) -> Void
    ) {
        withValidToken(completion: completion) { client, token in
            client.fetchMusicBrowse(browseId: browseId, token: token) {
                completion(.success($0))
            }
        }
    }

    /// Client/host pairs to try, first answer wins. The TV client on the
    /// YouTube Music host is what answers the TV sign-in; the YouTube Music
    /// web client turns it down (400 INVALID_ARGUMENT).
    private static let likedAlbumAttempts: [(host: String, client: [String: Any])] = [
        ("music.youtube.com", ["clientName": "TVHTML5", "clientVersion": "7.20260311.12.00", "hl": "en", "gl": "US"]),
        ("www.youtube.com", ["clientName": "TVHTML5", "clientVersion": "7.20260311.12.00", "hl": "en", "gl": "US"]),
        ("music.youtube.com", ["clientName": "WEB_REMIX", "clientVersion": "1.20260304.03.00", "hl": "en", "gl": "US"])
    ]

    func fetchMusicBrowse(
        browseId: String,
        token: String,
        attempt: Int = 0,
        completion: @escaping ([Playlist]) -> Void
    ) {
        let attempts = Self.likedAlbumAttempts
        guard attempt < attempts.count,
              let url = URL(
                  string: "https://\(attempts[attempt].host)/youtubei/v1/browse?prettyPrint=false"
              )
        else {
            completion([])
            return
        }
        let client = attempts[attempt].client
        let tag = "music(\(browseId))[\(attempts[attempt].host) \(client["clientName"] ?? "")]"
        let body: [String: Any] = [
            "context": ["client": client],
            "browseId": browseId
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let next = { [weak self] in
            guard let self else {
                completion([])
                return
            }
            self.fetchMusicBrowse(
                browseId: browseId, token: token, attempt: attempt + 1, completion: completion
            )
        }
        URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard error == nil, status == 200, let data,
                  let json = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any]
            else {
                let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                AppLog.innertube(
                    "\(tag): failed status=\(status) error=\(String(describing: error))"
                        + " body=\(text.prefix(600))"
                )
                next()
                return
            }
            let albums = Self.likedAlbums(in: json)
            AppLog.innertube(
                "\(tag): \(albums.count) — "
                    + albums.map { "\($0.title)=\($0.id)" }.joined(separator: ", ")
            )
            guard !albums.isEmpty else {
                AppLog.innertube(
                    "\(tag) response:\n" + AppLog.shape(of: json, maxDepth: 12).prefix(6_000)
                )
                next()
                return
            }
            completion(albums)
        }.resume()
    }

    /// Each album is a `musicTwoRowItemRenderer`; its play button carries the
    /// album's `OLAK5uy_…` playlist, which the TV client opens like any other.
    static func likedAlbums(in value: Any) -> [Playlist] {
        if let array = value as? [Any] {
            return array.flatMap { likedAlbums(in: $0) }
        }
        guard let dict = value as? [String: Any] else {
            return []
        }
        if let item = dict["musicTwoRowItemRenderer"] as? [String: Any] {
            guard let id = firstPlaylistId(in: item) else {
                return []
            }
            let thumbs = item.digDict("thumbnailRenderer", "musicThumbnailRenderer", "thumbnail")?[
                "thumbnails"
            ] as? [[String: Any]]
            return [Playlist(
                id: id,
                title: simpleText(from: item["title"]) ?? "",
                // "Album • Artist • 2024" / "Playlist • 25 songs"
                description: texts(in: item["subtitle"] as Any).joined(),
                thumbnailURL: thumbs?.last?["url"] as? String,
                itemCount: nil
            )]
        }
        if dict["tileRenderer"] != nil {
            return playlistTiles(in: dict)
        }
        return dict.values.flatMap { likedAlbums(in: $0) }
    }

    static func firstPlaylistId(in value: Any) -> String? {
        if let dict = value as? [String: Any] {
            if let id = dict["playlistId"] as? String, !id.isEmpty {
                return id
            }
            return dict.keys.sorted().lazy
                .compactMap { firstPlaylistId(in: dict[$0] as Any) }.first
        }
        if let array = value as? [Any] {
            return array.lazy.compactMap { firstPlaylistId(in: $0) }.first
        }
        return nil
    }
}
