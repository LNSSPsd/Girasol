import Foundation

// MARK: - Playlists

extension InnertubeClient {
    func executePlaylistsFetch(
        token: String,
        completion: @escaping (Result<[Playlist], Error>) -> Void
    ) {
        var body = tvContext
        body[JSONKey.browseId] = BrowseID.library
        execute(
            urlString: "\(baseURL)\(InnertubeEndpoint.browse)",
            body: body,
            headers: authHeaders(token: token),
            logTag: "playlistsFetch"
        ) { json -> [Playlist]? in
            Self.parsePlaylistTabs(json)
        } completion: { [weak self] result in
            guard let self else {
                return
            }
            self.handlePlaylistsFetchResult(result, token: token, completion: completion)
        }
    }

    func executePlaylistVideosFetch(
        playlistId: String,
        continuation: String?,
        token: String,
        completion: @escaping (Result<FeedPage, Error>) -> Void
    ) {
        var body = tvContext
        if let continuation {
            body[JSONKey.continuation] = continuation
        } else {
            body[JSONKey.browseId] = "VL\(playlistId)"
        }
        execute(
            urlString: "\(baseURL)\(InnertubeEndpoint.browse)",
            body: body,
            headers: authHeaders(token: token),
            logTag: "playlistVideos(\(playlistId))"
        ) { json -> FeedPage? in
            let list = Self.playlistVideoList(from: json)
            MusicPlaylistItems.collect(playlistId: playlistId, from: list?["contents"] as Any)
            // Album tracks name no artist of their own; the album header does.
            let artist = Self.albumArtist(from: json)
            let videos = Self.playlistVideos(from: list).map { video -> Video in
                guard video.channelName.isEmpty, let artist else {
                    return video
                }
                var credited = video
                credited.channelName = artist.name
                // The channel id is what the cell loads the avatar from.
                credited.channelId = credited.channelId ?? artist.channelId
                return credited
            }
            if videos.isEmpty {
                AppLog.innertube(
                    "playlist \(playlistId): no videos parsed, list=\(list != nil),"
                        + " response:\n" + AppLog.shape(of: json).prefix(12_000)
                )
            }
            let next = Self.playlistContinuation(from: list)
            AppLog.innertube(
                "playlist \(playlistId): \(videos.count) videos"
                    + " cont=\(next != nil)"
            )
            return videos.isEmpty
                ? nil
                : FeedPage(videos: videos, continuation: next)
        } completion: { completion($0) }
    }
}

// MARK: - Private Playlist Helpers

extension InnertubeClient {
    static func parsePlaylistTabs(
        _ json: [String: Any]
    ) -> [Playlist]? {
        let contents = json["contents"] as? [String: Any]
        let browse = contents?["tvBrowseRenderer"] as? [String: Any]
        let tabs = browse?["content"] as? [String: Any]
        let navRenderer = tabs?["tvSecondaryNavRenderer"] as? [String: Any]
        let sections = navRenderer?["sections"] as? [[String: Any]] ?? []
        // Own playlists and the ones saved from others (liked playlists,
        // albums) can sit in separate sections — read every one of them.
        let allTabs = sections.flatMap { section -> [[String: Any]] in
            let renderer = section["tvSecondaryNavSectionRenderer"]
                as? [String: Any]
            return renderer?["tabs"] as? [[String: Any]] ?? []
        }
        AppLog.innertube("library: \(sections.count) sections, \(allTabs.count) tabs")
        for tab in allTabs {
            let tr = tab["tabRenderer"] as? [String: Any]
            let browse = (tr?["endpoint"] as? [String: Any])?["browseEndpoint"]
                as? [String: Any]
            AppLog.innertube(
                "library tab \"\(tr?["title"] as? String ?? "?")\""
                    + " browseId=\(browse?["browseId"] as? String ?? "nil")"
                    + " params=\(browse?["params"] as? String ?? "nil")"
                    + " → \(browse.flatMap(playlistId(fromBrowse:)) ?? "rejected")"
                    + (tr == nil ? " keys=\(tab.keys.sorted())" : "")
            )
            if browse == nil {
                AppLog.innertube("library tab without browse:\n" + AppLog.shape(of: tab, maxDepth: 14).prefix(12_000))
            }
        }
        // Saved playlists and albums can come as tiles inside a tab's inline
        // content (the "Playlists" tab) rather than as tabs of their own.
        let tiles = playlistTiles(in: json)
        AppLog.innertube("library: \(tiles.count) playlist tiles: \(tiles.map(\.id))")
        var seen = Set<String>()
        return (allTabs.compactMap { tab in
            parsePlaylistTab(tab)
        } + tiles)
        .filter { seen.insert($0.id).inserted }
    }

    /// Every tile anywhere in the response that opens a playlist page.
    static func playlistTiles(in value: Any) -> [Playlist] {
        if let array = value as? [Any] {
            return array.flatMap { playlistTiles(in: $0) }
        }
        guard let dict = value as? [String: Any] else {
            return []
        }
        if let tile = dict["tileRenderer"] as? [String: Any],
           let browseId = tile.digString("onSelectCommand", "browseEndpoint", "browseId"),
           browseId.hasPrefix("VL"), browseId.count > 2 {
            let meta = tile.digDict("metadata", "tileMetadataRenderer")
            return [Playlist(
                id: String(browseId.dropFirst(2)),
                title: simpleText(from: meta?["title"]) ?? "",
                description: tileLines(meta),
                // The cover sits in the tile header.
                thumbnailURL: lastThumbnailURL(in: tile["header"] as Any),
                itemCount: nil
            )]
        }
        return dict.keys.sorted().flatMap { playlistTiles(in: dict[$0] as Any) }
    }

    /// A tile's metadata lines ("Artist • 2024"), one line each.
    static func tileLines(_ meta: [String: Any]?) -> String {
        let lines = meta?["lines"] as? [Any] ?? []
        return lines.map { texts(in: $0).joined() }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    static func parsePlaylistTab(
        _ tab: [String: Any]
    ) -> Playlist? {
        guard let tr = tab["tabRenderer"] as? [String: Any],
              let title = tr["title"] as? String,
              let endpoint = tr["endpoint"] as? [String: Any],
              let browse = endpoint["browseEndpoint"] as? [String: Any],
              let playlistId = playlistId(fromBrowse: browse)
        else {
            return nil
        }
        return Playlist(
            id: playlistId,
            title: title,
            description: "",
            thumbnailURL: nil,
            itemCount: nil
        )
    }

    /// Library tabs name their playlist inside `params`; a saved playlist
    /// can instead point straight at its `VL…` browse page.
    static func playlistId(fromBrowse browse: [String: Any]) -> String? {
        if let params = browse["params"] as? String,
           let id = extractPlaylistIdFromParams(params) {
            return id
        }
        guard let browseId = browse["browseId"] as? String,
              browseId.hasPrefix("VL"), browseId.count > 2
        else {
            return nil
        }
        return String(browseId.dropFirst(2))
    }

    /// The list renderer for both shapes: page one nests it under the
    /// browse surface, continuation pages return it at the top level.
    static func playlistVideoList(
        from json: [String: Any]
    ) -> [String: Any]? {
        if let continued = (
            json["continuationContents"] as? [String: Any]
        )?["playlistVideoListContinuation"] as? [String: Any] {
            return continued
        }
        let contents = json["contents"] as? [String: Any]
        let browse = contents?["tvBrowseRenderer"] as? [String: Any]
        let rightCol = browse?["content"] as? [String: Any]
        let surface = rightCol?["tvSurfaceContentRenderer"] as? [String: Any]
        let surfaceContent = surface?["content"] as? [String: Any]
        let twoCol = surfaceContent?["twoColumnRenderer"] as? [String: Any]
        let right = twoCol?["rightColumn"] as? [String: Any]
        return right?["playlistVideoListRenderer"] as? [String: Any]
    }

    static func playlistVideos(
        from list: [String: Any]?
    ) -> [Video] {
        let items = list?["contents"] as? [[String: Any]] ?? []
        let tiles = items.compactMap { $0["tileRenderer"] as? [String: Any] }
        // The duration overlay marks a video tile in a normal playlist; album
        // tracks come without one, so a video content type counts as well.
        let videos = tiles.filter { tile in
            tile.digDict("header", "tileHeaderRenderer")?["thumbnailOverlays"] != nil
                || tile["contentType"] as? String == "TILE_CONTENT_TYPE_VIDEO"
        }
        .compactMap(InnertubeClient.parseTileRenderer)
        if videos.isEmpty, let first = items.first {
            AppLog.innertube("playlist item:\n" + AppLog.shape(of: first, maxDepth: 14).prefix(8_000))
        }
        // Neither marker: take every tile that opens a video.
        let parsed = videos.isEmpty
            ? tiles.compactMap(InnertubeClient.parseTileRenderer) : videos
        return parsed.map { video in
            guard video.title.isEmpty,
                  let tile = tiles.first(where: {
                      $0.digString("onSelectCommand", "watchEndpoint", "videoId") == video.id
                  })
            else {
                return video
            }
            // Album tracks: `trackTileHeaderRenderer` holds title and length.
            let track = tile.digDict("header", "trackTileHeaderRenderer")
            let title = simpleText(from: track?["title"]) ?? anyTitle(in: tile) ?? ""
            if track == nil {
                AppLog.innertube(
                    "playlist tile \(video.id) without a metadata title, found \"\(title)\":\n"
                        + AppLog.shape(of: tile, maxDepth: 14).prefix(8_000)
                )
            }
            return Video(
                id: video.id,
                title: title,
                channelId: video.channelId,
                channelName: video.channelName,
                channelAvatarURL: video.channelAvatarURL,
                thumbnailURL: video.thumbnailURL,
                viewCount: video.viewCount,
                publishedAt: video.publishedAt,
                duration: video.duration ?? simpleText(from: track?["duration"]),
                isLive: video.isLive,
                playlistId: video.playlistId,
                isShort: video.isShort
            )
        }
    }

    /// The first byline of the page header (`entityMetadataRenderer`), which
    /// on an album page is its artist. Continuation pages have no header.
    static func albumArtist(
        from json: [String: Any]
    ) -> (name: String, channelId: String?)? {
        let header = json.digDict(
            "contents", "tvBrowseRenderer", "content", "tvSurfaceContentRenderer",
            "content", "twoColumnRenderer", "leftColumn", "entityMetadataRenderer"
        )
        guard let byline = (header?["bylines"] as? [Any])?.first else {
            return nil
        }
        // "Artist•10 songs•2024": the artist is the first part.
        let full = texts(in: byline).joined()
        let text = (full.components(separatedBy: "•").first ?? "")
            .trimmingCharacters(in: .whitespaces)
        let channelId = firstChannelId(in: byline)
        AppLog.innertube(
            "album byline: \"\(full)\" → \"\(text)\" channel=\(channelId ?? "nil")"
        )
        return text.isEmpty ? nil : (text, channelId)
    }

    /// The artist link in the byline: the first `UC…` browse id.
    static func firstChannelId(in value: Any) -> String? {
        if let array = value as? [Any] {
            return array.lazy.compactMap { firstChannelId(in: $0) }.first
        }
        guard let dict = value as? [String: Any] else {
            return nil
        }
        if let id = dict["browseId"] as? String, id.hasPrefix("UC") {
            return id
        }
        return dict.keys.sorted().lazy
            .compactMap { firstChannelId(in: dict[$0] as Any) }.first
    }

    /// Every `simpleText` / `text` string, arrays in order.
    static func texts(in value: Any) -> [String] {
        if let array = value as? [Any] {
            return array.flatMap { texts(in: $0) }
        }
        guard let dict = value as? [String: Any] else {
            return []
        }
        if let text = dict["simpleText"] as? String ?? dict["text"] as? String {
            return [text]
        }
        return dict.keys.sorted().flatMap { key -> [String] in
            key == "accessibility" ? [] : texts(in: dict[key] as Any)
        }
    }

    /// Album tracks keep their name outside `tileMetadataRenderer`: the first
    /// text under any `title` key, else the first accessibility label.
    static func anyTitle(in value: Any) -> String? {
        firstText(in: value, key: "title") ?? firstLabel(in: value)
    }

    static func firstText(in value: Any, key: String) -> String? {
        if let dict = value as? [String: Any] {
            if let text = simpleText(from: dict[key]) ?? (dict[key] as? String),
               !text.isEmpty {
                return text
            }
            return dict.keys.sorted().lazy
                .compactMap { firstText(in: dict[$0] as Any, key: key) }.first
        }
        if let array = value as? [Any] {
            return array.lazy.compactMap { firstText(in: $0, key: key) }.first
        }
        return nil
    }

    static func firstLabel(in value: Any) -> String? {
        if let dict = value as? [String: Any] {
            if let label = (dict["accessibilityData"] as? [String: Any])?["label"] as? String,
               !label.isEmpty {
                return label
            }
            return dict.keys.sorted().lazy
                .compactMap { firstLabel(in: dict[$0] as Any) }.first
        }
        if let array = value as? [Any] {
            return array.lazy.compactMap { firstLabel(in: $0) }.first
        }
        return nil
    }

    static func playlistContinuation(
        from list: [String: Any]?
    ) -> String? {
        let continuations = list?["continuations"] as? [[String: Any]]
        let next = continuations?.first?["nextContinuationData"]
            as? [String: Any]
        return next?["continuation"] as? String
    }

    static func playlistVideoItems(
        from json: [String: Any]
    ) -> [[String: Any]] {
        playlistVideoList(from: json)?["contents"] as? [[String: Any]] ?? []
    }

    /// Playlists the TV library browse never lists: Watch Later, and the
    /// legacy Favorites list on accounts old enough to have one.
    static func implicitPlaylists(
        besides playlists: [Playlist]
    ) -> [Playlist] {
        let known = Set(playlists.map(\.id))
        let watchLater = Playlist(
            id: "WL",
            title: "Watch Later",
            description: "",
            thumbnailURL: nil,
            itemCount: nil
        )
        let legacy = legacyFavoritesId.map {
            Playlist(
                id: $0,
                title: "library.playlists.favorites".localized,
                description: "",
                thumbnailURL: nil,
                itemCount: nil
            )
        }
        return ([watchLater] + [legacy].compactMap { $0 })
            .filter { !known.contains($0.id) }
    }

    func handlePlaylistsFetchResult(
        _ result: Result<[Playlist], Error>,
        token: String,
        completion: @escaping (Result<[Playlist], Error>) -> Void
    ) {
        switch result {
        case .failure(let error):
            completion(.failure(error))
        case .success(let playlists):
            let all = Self.implicitPlaylists(besides: playlists)
                + playlists
            guard !all.isEmpty else {
                completion(.success(all))
                return
            }
            fetchAllThumbnails(
                playlists: all,
                token: token,
                completion: completion
            )
        }
    }

    func fetchAllThumbnails(
        playlists: [Playlist],
        token: String,
        completion: @escaping (Result<[Playlist], Error>) -> Void
    ) {
        let group = DispatchGroup()
        var thumbnails: [String: String] = [:]
        let lock = NSLock()
        for playlist in playlists {
            group.enter()
            fetchPlaylistFirstThumbnail(
                playlistId: playlist.id,
                token: token
            ) { url in
                if let url {
                    lock.lock()
                    thumbnails[playlist.id] = url
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .global()) {
            let result = playlists.map { pl in
                Playlist(
                    id: pl.id,
                    title: pl.title,
                    description: pl.description,
                    thumbnailURL: thumbnails[pl.id] ?? pl.thumbnailURL,
                    itemCount: pl.itemCount
                )
            }
            completion(.success(result))
        }
    }

    func fetchPlaylistFirstThumbnail(
        playlistId: String,
        token: String,
        completion: @escaping (String?) -> Void
    ) {
        var body = tvContext
        body["browseId"] = "VL\(playlistId)"
        execute(
            urlString: "\(baseURL)\(InnertubeEndpoint.browse)",
            body: body,
            headers: authHeaders(token: token),
            logTag: "playlistThumb(\(playlistId))"
        ) { json -> String? in
            let items = Self.playlistVideoItems(from: json)
            for item in items {
                if let tile = item["tileRenderer"] as? [String: Any],
                   let video = InnertubeClient.parseTileRenderer(tile) {
                    return video.thumbnailURL
                }
            }
            return nil
        } completion: { result in
            completion(try? result.get())
        }
    }
}
