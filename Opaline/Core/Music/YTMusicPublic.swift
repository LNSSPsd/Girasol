import Foundation

// MARK: - Models

struct MusicArtistRef {
    let browseId: String
    let name: String
    let subtitle: String
    let thumbnailURL: String?
}

struct MusicAlbumRef {
    /// `MPREb_…`: the album page.
    let browseId: String
    let title: String
    let subtitle: String
    let thumbnailURL: String?
}

enum MusicEntry {
    case song(Video)
    case album(MusicAlbumRef)
    case artist(MusicArtistRef)
    case playlist(Playlist)
}

struct MusicArtistPage {
    let name: String
    let thumbnailURL: String?
    /// The artist's own songs, shuffled ("Play"): playlist and first song.
    let shuffle: (playlistId: String, videoId: String?)?
    /// Artist radio.
    let radioPlaylistId: String?
    let topSongs: [Video]
    let albums: [MusicAlbumRef]
    let singles: [MusicAlbumRef]
    /// Every shelf of the page in order — for a channel that is not an
    /// artist (only videos and playlists) this is all there is.
    let shelves: [(title: String, entries: [MusicEntry])]
}

struct MusicAlbumPage {
    let title: String
    let subtitle: String
    let artist: MusicArtistRef?
    let thumbnailURL: String?
    /// `OLAK5uy_…`: what the TV client and downloads open.
    let playlistId: String?
    let tracks: [Video]
}

/// A slice of a watch queue (shuffle, radio) and where it goes on.
struct MusicWatchQueue {
    let tracks: [Video]
    let continuation: String?
    /// What YouTube Music plays after this playlist (`RDAMPL<id>`): named
    /// only when the request could read the playlist.
    var automix: (playlistId: String, params: String?)?
}

/// Where a song came from, for "Go to album" / "Go to artist". Noted
/// whenever a YouTube Music response names them.
enum MusicTrackLinks {
    private static let lock = NSLock()
    private static var artists: [String: MusicArtistRef] = [:]
    private static var albums: [String: MusicAlbumRef] = [:]

    static func note(_ videoId: String, artist: MusicArtistRef?, album: MusicAlbumRef?) {
        lock.lock()
        if let artist {
            artists[videoId] = artist
        }
        if let album {
            albums[videoId] = album
        }
        lock.unlock()
    }

    static func links(of videoId: String) -> (artist: MusicArtistRef?, album: MusicAlbumRef?) {
        lock.lock()
        defer { lock.unlock() }
        return (artists[videoId], albums[videoId])
    }
}

// MARK: - Requests

/// YouTube Music's public pages — search, artists, albums, watch queues —
/// through its own web client, signed out: the TV sign-in is refused there,
/// and none of these need an account. The library stays on the TV client.
/// The optional web account (`OPMusicWebAccount`) adds what only it can
/// reach: the personal home and creating playlists.
enum YTMusicPublic {
    static let searchFilters: [(title: String, params: String)] = [
        ("Songs", "EgWKAQIIAWoSEAUQCRAKEAMQEBAEEBUQDhAR"),
        ("Albums", "EgWKAQIYAWoSEAUQCRAKEAMQEBAEEBUQDhAR"),
        ("Artists", "EgWKAQIgAWoSEAUQCRAKEAMQEBAEEBUQDhAR")
    ]

    private static let clientVersion = "1.20260304.03.00"

    private static let origin = "https://music.youtube.com"

    /// Cookies are never stored or sent by the session itself: signed out
    /// stays signed out, and the web account (`signedIn`) sends its own.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        return URLSession(configuration: config)
    }()

    /// `signedIn` sends the optional web account (`OPMusicWebAccount`) when
    /// there is one; without it the request goes signed out as always.
    /// `visitorData` ties a continuation to the visitor of its first page —
    /// signed out, YouTube Music answers a home continuation without it with
    /// an empty page.
    static func post(
        _ endpoint: String,
        _ body: [String: Any],
        tag: String,
        signedIn: Bool = false,
        visitorData: String? = nil,
        hl: String = "en",
        completion: @escaping ([String: Any]?) -> Void
    ) {
        guard let url = URL(string: "\(origin)/youtubei/v1/\(endpoint)?prettyPrint=false") else {
            completion(nil)
            return
        }
        var client: [String: Any] = [
            "clientName": "WEB_REMIX", "clientVersion": clientVersion, "hl": hl, "gl": "US"
        ]
        var full = body
        var request = URLRequest(url: url)
        if let visitorData {
            client["visitorData"] = visitorData
            request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }
        full["context"] = ["client": client]
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: full)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue("67", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        let account = signedIn ? OPMusicWebAccount.headers(forOrigin: origin) : nil
        for (field, value) in account ?? [:] {
            request.setValue(value, forHTTPHeaderField: field)
        }
        session.dataTask(with: request) { data, response, error in
            if account != nil {
                OPMusicWebAccount.note(response)
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard error == nil, status == 200, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                AppLog.innertube(
                    "ytmusic \(tag)\(account != nil ? " (web account)" : ""): failed status=\(status)"
                        + " error=\(String(describing: error)) body=\(text.prefix(300))"
                )
                completion(nil)
                return
            }
            completion(json)
        }.resume()
    }

    static func search(
        _ query: String,
        filter params: String,
        completion: @escaping ([MusicEntry]) -> Void
    ) {
        let body: [String: Any] = ["query": query, "params": params]
        post("search", body, tag: "search") { json in
            let entries = json.map { listItems(in: $0).compactMap(entry) } ?? []
            AppLog.innertube("ytmusic search \"\(query)\": \(entries.count) results")
            let songs = entries.compactMap { entry -> Video? in
                guard case let .song(video) = entry else {
                    return nil
                }
                return video
            }
            MusicNativeNames.lookUp(songs)
            nativeNames(of: songs, endpoint: "search", body: body, tag: "search ja") { names, _ in
                let entries = entries.map { entry -> MusicEntry in
                    guard case let .song(video) = entry else {
                        return entry
                    }
                    return .song(native(video, names))
                }
                DispatchQueue.main.async { completion(entries) }
            }
        }
    }

    static func artist(
        _ browseId: String,
        completion: @escaping (MusicArtistPage?) -> Void
    ) {
        post("browse", ["browseId": browseId], tag: "artist(\(browseId))") { json in
            let page = json.flatMap { parseArtist($0, browseId: browseId) }
            MusicNativeNames.lookUp(page?.topSongs ?? [])
            DispatchQueue.main.async { completion(page) }
        }
    }

    static func album(
        _ browseId: String,
        completion: @escaping (MusicAlbumPage?) -> Void
    ) {
        post("browse", ["browseId": browseId], tag: "album(\(browseId))") { json in
            let page = json.flatMap { parseAlbum($0, browseId: browseId) }
            nativeNames(
                of: page?.tracks ?? [], endpoint: "browse", body: ["browseId": browseId], tag: "album ja"
            ) { names, japanese in
                let page = page.map { native($0, browseId: browseId, names, header: japanese) }
                DispatchQueue.main.async { completion(page) }
            }
        }
    }

    /// A watch queue: a playlist (shuffle `RDAO…`, radio `RDEM…`/`RDAMVM…`)
    /// from its start, or its next slice by continuation.
    static func watchQueue(
        playlistId: String?,
        videoId: String?,
        params: String? = nil,
        continuation: String? = nil,
        signedIn: Bool = false,
        completion: @escaping (MusicWatchQueue?) -> Void
    ) {
        var body: [String: Any] = [:]
        if let continuation {
            body["continuation"] = continuation
        } else {
            body["playlistId"] = playlistId
            if let videoId {
                body["videoId"] = videoId
            }
            if let params {
                body["params"] = params
            }
            body["isAudioOnly"] = true
        }
        post("next", body, tag: "queue(\(playlistId ?? "continuation"))", signedIn: signedIn) { json in
            var queue = json.map(parseWatchQueue)
            AppLog.innertube(
                "ytmusic queue \(playlistId ?? "continued"): \(queue?.tracks.count ?? 0) tracks,"
                    + " more=\(queue?.continuation != nil)"
            )
            nativeNames(
                of: queue?.tracks ?? [], endpoint: "next", body: body, tag: "queue ja", signedIn: signedIn
            ) { names, _ in
                if let tracks = queue?.tracks {
                    // A radio's Japanese copy names other songs: the artists
                    // it did not cover are asked about one by one.
                    MusicNativeNames.lookUp(tracks)
                    queue = MusicWatchQueue(
                        tracks: tracks.map { native($0, names) },
                        continuation: queue?.continuation,
                        automix: queue?.automix
                    )
                }
                DispatchQueue.main.async { completion(queue) }
            }
        }
    }

    /// A temporary playlist (`TLGG…`, signed out, about a day) of up to 50
    /// videos: what youtube.com's `watch_videos` redirects to. Its automix
    /// (`RDAMPL<id>`) is YouTube's recommendations for that whole list:
    /// music mode's mix of the last songs played. More than 50 ids are
    /// silently cut to the first 50.
    static func temporaryPlaylist(videoIds: [String], completion: @escaping (String?) -> Void) {
        let ids = videoIds.prefix(50).joined(separator: ",")
        guard !ids.isEmpty, let url = URL(string: "https://www.youtube.com/watch_videos?video_ids=\(ids)") else {
            completion(nil)
            return
        }
        redirectSession.dataTask(with: url) { _, response, error in
            let location = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location") ?? ""
            let list = URLComponents(string: location)?.queryItems?.first { $0.name == "list" }?.value
            AppLog.innertube(
                "ytmusic temporary playlist of \(videoIds.prefix(50).count): \(list ?? "none")"
                    + (error.map { " error=\($0)" } ?? "")
            )
            DispatchQueue.main.async { completion(list) }
        }.resume()
    }

    /// Like `session`, but hands back a redirect instead of following it:
    /// the playlist id is in `watch_videos`' Location, and the watch page
    /// behind it is a megabyte of HTML.
    private static let redirectSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        return URLSession(configuration: config, delegate: RedirectRefuser(), delegateQueue: nil)
    }()

    private final class RedirectRefuser: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    /// YouTube Music's own home: personal with the web account, the public
    /// one (charts, moods, new releases) without it — so Home has shelves
    /// either way. First page and up to `pages - 1` continuations. A web
    /// account that is refused falls back to the public home.
    static func home(
        pages: Int = 4,
        completion: @escaping ([(title: String, entries: [MusicEntry])]) -> Void
    ) {
        home(signedIn: OPMusicWebAccount.signedIn, pages: pages, completion: completion)
    }

    private static func home(
        signedIn: Bool,
        pages: Int,
        completion: @escaping ([(title: String, entries: [MusicEntry])]) -> Void
    ) {
        post("browse", ["browseId": "FEmusic_home"], tag: "home", signedIn: signedIn) { json in
            guard let json else {
                if signedIn {
                    home(signedIn: false, pages: pages, completion: completion)
                } else {
                    DispatchQueue.main.async { completion([]) }
                }
                return
            }
            let list = json.digDict("contents", "singleColumnBrowseResultsRenderer")
                .flatMap { ($0["tabs"] as? [[String: Any]])?.first }?
                .digDict("tabRenderer", "content", "sectionListRenderer")
            let visitor = json.digString("responseContext", "visitorData")?.removingPercentEncoding
            homePages(
                list, visitor: visitor, signedIn: signedIn, left: pages - 1, found: []
            ) { shelves in
                AppLog.innertube(
                    "ytmusic home\(signedIn ? " (web account)" : ""): \(shelves.count) shelves"
                        + " (\(shelves.map(\.title).joined(separator: ", ")))"
                )
                DispatchQueue.main.async { completion(shelves) }
            }
        }
    }

    /// Collects the shelves of `list` and follows its continuation.
    private static func homePages(
        _ list: [String: Any]?,
        visitor: String?,
        signedIn: Bool,
        left: Int,
        found: [(title: String, entries: [MusicEntry])],
        completion: @escaping ([(title: String, entries: [MusicEntry])]) -> Void
    ) {
        let shelves = found + entryShelves(list?["contents"] as? [[String: Any]] ?? [])
        let token = ((list?["continuations"] as? [[String: Any]])?.first?["nextContinuationData"]
            as? [String: Any])?["continuation"] as? String
        guard left > 0, let token else {
            completion(shelves)
            return
        }
        post(
            "browse", ["continuation": token.removingPercentEncoding ?? token],
            tag: "home(more)", signedIn: signedIn, visitorData: visitor
        ) { json in
            homePages(
                json?.digDict("continuationContents", "sectionListContinuation"),
                visitor: visitor, signedIn: signedIn, left: left - 1, found: shelves,
                completion: completion
            )
        }
    }

    /// Creates a playlist with the web account (the TV sign-in cannot);
    /// nil when signed out of it or refused.
    static func createPlaylist(
        title: String,
        privacyStatus: String,
        videoIds: [String],
        completion: @escaping (String?) -> Void
    ) {
        guard OPMusicWebAccount.signedIn else {
            completion(nil)
            return
        }
        var body: [String: Any] = ["title": title, "description": "", "privacyStatus": privacyStatus]
        if !videoIds.isEmpty {
            body["videoIds"] = videoIds
        }
        post("playlist/create", body, tag: "createPlaylist", signedIn: true) { json in
            let id = json?["playlistId"] as? String
            AppLog.innertube("ytmusic createPlaylist (web account): \(id ?? "refused")")
            completion(id)
        }
    }

    /// The web account's saved playlists (Library → Playlists), every page;
    /// nil when signed out of it or refused. Where `createPlaylist`'s
    /// playlists show up at once — the TV token's list is only right when
    /// both sign-ins are the same account and channel.
    static func libraryPlaylists(completion: @escaping ([Playlist]?) -> Void) {
        guard OPMusicWebAccount.signedIn else {
            completion(nil)
            return
        }
        library("FEmusic_liked_playlists") { entries in
            let playlists = entries?.compactMap { entry -> Playlist? in
                guard case .playlist(let playlist) = entry else {
                    return nil
                }
                return playlist
            }
            AppLog.innertube("ytmusic library (web account): \(playlists.map { "\($0.count) playlists" } ?? "refused")")
            completion(playlists)
        }
    }

    /// The artists the web account follows, as YouTube Music lists them
    /// (Library → Artists): one request instead of checking every channel
    /// followed. Nil when signed out of it or refused.
    static func libraryArtists(completion: @escaping ([MusicArtistRef]?) -> Void) {
        guard OPMusicWebAccount.signedIn else {
            completion(nil)
            return
        }
        library("FEmusic_library_corpus_artists") { entries in
            let artists = entries?.compactMap { entry -> MusicArtistRef? in
                guard case .artist(let artist) = entry else {
                    return nil
                }
                return artist
            }
            AppLog.innertube("ytmusic library artists (web account): \(artists.map { "\($0.count)" } ?? "refused")")
            completion(artists)
        }
    }

    /// A library page with the web account, every page of it. Main queue.
    private static func library(_ browseId: String, completion: @escaping ([MusicEntry]?) -> Void) {
        post("browse", ["browseId": browseId], tag: "library(\(browseId))", signedIn: true) { json in
            guard let json else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            libraryPages(json["contents"] as Any, from: json, left: 10, found: []) { entries in
                DispatchQueue.main.async { completion(entries) }
            }
        }
    }

    private static func libraryPages(
        _ contents: Any,
        from json: [String: Any],
        left: Int,
        found: [MusicEntry],
        completion: @escaping ([MusicEntry]) -> Void
    ) {
        let playlists = found + listItems(in: contents).compactMap(entry)
        let token = firstDict(named: "nextContinuationData", in: json)?["continuation"] as? String
            ?? firstDict(named: "continuationCommand", in: json)?["token"] as? String
        guard left > 0, let token else {
            completion(playlists)
            return
        }
        post(
            "browse", ["continuation": token.removingPercentEncoding ?? token],
            tag: "library(more)", signedIn: true
        ) { json in
            guard let json else {
                completion(playlists)
                return
            }
            libraryPages(
                json["continuationContents"] ?? json["onResponseReceivedActions"] as Any,
                from: json, left: left - 1, found: playlists, completion: completion
            )
        }
    }

    /// A playlist read with the web account, every page: private and empty
    /// ones too (the TV client fails on an empty one), whether it is the
    /// account's own (the editable header), and its entry ids for
    /// reordering. Nil when signed out of it or refused.
    static func playlist(
        _ playlistId: String,
        completion: @escaping ((tracks: [Video], entryIds: [String?], isOwn: Bool)?) -> Void
    ) {
        guard OPMusicWebAccount.signedIn else {
            completion(nil)
            return
        }
        post("browse", ["browseId": "VL\(playlistId)"], tag: "playlist(\(playlistId))", signedIn: true) { json in
            guard let json, json["contents"] != nil else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let isOwn = firstDict(named: "musicEditablePlaylistDetailHeaderRenderer", in: json) != nil
            // Only the playlist's own shelf: an own playlist's page also
            // suggests songs.
            let shelf = firstDict(named: "musicPlaylistShelfRenderer", in: json) ?? [:]
            playlistPages(shelf, playlistId: playlistId, left: 50, found: []) { rows in
                AppLog.innertube(
                    "ytmusic playlist \(playlistId) (web account): \(rows.count) tracks,"
                        + " \(rows.filter { $0.entryId != nil }.count) entry ids\(isOwn ? ", own" : "")"
                )
                DispatchQueue.main.async { completion((rows.map(\.video), rows.map(\.entryId), isOwn)) }
            }
        }
    }

    private static func playlistPages(
        _ page: Any,
        playlistId: String,
        left: Int,
        found: [(video: Video, entryId: String?)],
        completion: @escaping ([(video: Video, entryId: String?)]) -> Void
    ) {
        MusicPlaylistItems.collect(playlistId: playlistId, from: page)
        // Each row with its own entry id: a song in the list twice has two.
        let tracks = found + listItems(in: page).compactMap { item -> (video: Video, entryId: String?)? in
            guard case .song(let video) = entry(item) else {
                return nil
            }
            let entryId = item.digString("playlistItemData", "playlistSetVideoId")
                ?? firstString(named: "setVideoId", in: item)
            return (video, entryId)
        }
        guard left > 0, let token = firstDict(named: "continuationCommand", in: page)?["token"] as? String else {
            completion(tracks)
            return
        }
        post("browse", ["continuation": token], tag: "playlist(more)", signedIn: true) { json in
            guard let actions = json?["onResponseReceivedActions"] else {
                completion(tracks)
                return
            }
            playlistPages(actions, playlistId: playlistId, left: left - 1, found: tracks, completion: completion)
        }
    }

    /// The web account's own playlists for "Add to playlist", with whether
    /// `videoId` is in each and the edit actions to add or remove it. Nil
    /// when signed out of it or refused.
    static func addToPlaylistOptions(videoId: String, completion: @escaping ([PlaylistAddOption]?) -> Void) {
        guard OPMusicWebAccount.signedIn else {
            completion(nil)
            return
        }
        post(
            "playlist/get_add_to_playlist", ["videoIds": [videoId], "excludeWatchLater": true],
            tag: "addToPlaylist(\(videoId))", signedIn: true
        ) { json in
            let options = json.map(InnertubeClient.parseAddToPlaylistOptions)
            AppLog.innertube("ytmusic add-to-playlist (web account): \(options.map { "\($0.count) playlists" } ?? "refused")")
            completion(options)
        }
    }

    /// Title, description, privacy, songs, order — YouTube's playlist edit
    /// actions, with the web account. Nil when signed out of it.
    static func editPlaylist(_ playlistId: String, actions: [[String: Any]], completion: @escaping (Bool?) -> Void) {
        guard OPMusicWebAccount.signedIn else {
            completion(nil)
            return
        }
        post(
            "browse/edit_playlist", ["playlistId": playlistId, "actions": actions],
            tag: "editPlaylist(\(playlistId))", signedIn: true
        ) { json in
            let ok = (json?["status"] as? String) == "STATUS_SUCCEEDED"
            AppLog.innertube("ytmusic editPlaylist \(playlistId) (web account): \(ok ? "ok" : "refused")")
            completion(ok)
        }
    }

    /// Adds `videoId` to a playlist even when it is there already (a second
    /// copy, as asked) — YouTube's add checks for duplicates unless told to
    /// skip that. The new row's entry id, "" when YouTube did not name it;
    /// nil when signed out of the web account or refused.
    static func addToPlaylist(_ playlistId: String, videoId: String, completion: @escaping (String?) -> Void) {
        guard OPMusicWebAccount.signedIn else {
            completion(nil)
            return
        }
        let actions: [[String: Any]] = [
            ["action": "ACTION_ADD_VIDEO", "addedVideoId": videoId, "dedupeOption": "DEDUPE_OPTION_SKIP"]
        ]
        post(
            "browse/edit_playlist", ["playlistId": playlistId, "actions": actions],
            tag: "addToPlaylist(\(playlistId))", signedIn: true
        ) { json in
            guard let json, (json["status"] as? String) == "STATUS_SUCCEEDED" else {
                AppLog.innertube("ytmusic add \(videoId) to \(playlistId) (web account): refused")
                completion(nil)
                return
            }
            let entryId = firstDict(named: "playlistEditVideoAddedResultData", in: json)?["setVideoId"] as? String
            AppLog.innertube("ytmusic add \(videoId) to \(playlistId) (web account): entry \(entryId ?? "?")")
            completion(entryId ?? "")
        }
    }

    /// Deletes one of the web account's playlists. Nil when signed out of it.
    static func deletePlaylist(_ playlistId: String, completion: @escaping (Bool?) -> Void) {
        guard OPMusicWebAccount.signedIn else {
            completion(nil)
            return
        }
        post("playlist/delete", ["playlistId": playlistId], tag: "deletePlaylist(\(playlistId))", signedIn: true) { json in
            // An empty 200 is the success answer.
            AppLog.innertube("ytmusic deletePlaylist \(playlistId) (web account): \(json != nil ? "ok" : "refused")")
            completion(json != nil)
        }
    }

    /// Where to report a play so it lands in YouTube Music's history (the
    /// web account's) rather than the TV sign-in's YouTube history. Nil when
    /// signed out of the web account or refused — then nothing is reported.
    static func playbackTracking(videoId: String, completion: @escaping (WatchtimeURLs?) -> Void) {
        guard OPMusicWebAccount.signedIn else {
            completion(nil)
            return
        }
        post("player", ["videoId": videoId], tag: "player(\(videoId))", signedIn: true) { json in
            let urls = json.flatMap(InnertubeClient.extractWatchtimeURLs)
            AppLog.innertube("ytmusic play report for \(videoId) (web account): \(urls != nil ? "ready" : "refused")")
            DispatchQueue.main.async { completion(urls) }
        }
    }

    /// YouTube Music's own listening history (the web account's), newest
    /// first; nil when signed out of it or refused.
    static func history(completion: @escaping ([Video]?) -> Void) {
        guard OPMusicWebAccount.signedIn else {
            completion(nil)
            return
        }
        post("browse", ["browseId": "FEmusic_history"], tag: "history", signedIn: true) { json in
            let songs = json.map { listItems(in: $0["contents"] as Any) }?.compactMap { item -> Video? in
                guard case .song(let video) = entry(item) else {
                    return nil
                }
                return video
            }
            AppLog.innertube("ytmusic history (web account): \(songs.map { "\($0.count) songs" } ?? "refused")")
            DispatchQueue.main.async { completion(songs) }
        }
    }

    /// Which Google account and channel the web account is, for the log:
    /// playlists it creates belong to that channel.
    static func logWebAccountIdentity() {
        guard OPMusicWebAccount.signedIn else {
            return
        }
        post("account/account_menu", [:], tag: "account", signedIn: true) { json in
            let header = json.flatMap { firstDict(named: "activeAccountHeaderRenderer", in: $0) }
            AppLog.innertube(
                "ytmusic web account is \(texts(header?["accountName"]))"
                    + " (\(texts(header?["channelHandle"])))"
            )
        }
    }

    /// An album playlist (`OLAK…`) as youtube.com lists it, in order: where
    /// YouTube Music's own album page puts a track's music video, this
    /// list has the song itself (the "Artist - Topic" upload). Signed out;
    /// nil when refused.
    /// Lengths the youtube.com album lists gave ("2:58"), by song id: a
    /// swapped-in song shows its own length, not its music video's.
    private static var songLengths: [String: String] = [:]
    private static let songLengthLock = NSLock()

    static func songLength(of videoId: String) -> String? {
        songLengthLock.lock()
        defer { songLengthLock.unlock() }
        return songLengths[videoId]
    }

    static func albumSongIds(playlistId: String, completion: @escaping ([String]?) -> Void) {
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/browse?prettyPrint=false") else {
            completion(nil)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "context": ["client": ["clientName": "WEB", "clientVersion": "2.20260301.00.00", "hl": "en"]],
            "browseId": "VL\(playlistId)"
        ])
        session.dataTask(with: request) { data, _, _ in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            var lockups: [[String: Any]] = []
            var rows: [[String: Any]] = []
            if let json {
                collect("lockupViewModel", in: json, into: &lockups)
                collect("playlistVideoRenderer", in: json, into: &rows)
            }
            let ids = lockups.isEmpty
                ? rows.compactMap { $0["videoId"] as? String }
                : lockups.compactMap { $0["contentId"] as? String }
            songLengthLock.lock()
            for lockup in lockups {
                var badges: [[String: Any]] = []
                collect("thumbnailBadgeViewModel", in: lockup, into: &badges)
                let length = badges.lazy.compactMap { $0["text"] as? String }
                    .first { $0.range(of: #"^\d+(:\d\d){1,2}$"#, options: .regularExpression) != nil }
                if let id = lockup["contentId"] as? String, let length {
                    songLengths[id] = length
                }
            }
            songLengthLock.unlock()
            AppLog.innertube("youtube album \(playlistId): \(json == nil ? "refused" : "\(ids.count) songs")")
            completion(json == nil ? nil : ids)
        }.resume()
    }

    /// The raw contents of a playlist's public page, for its entry ids.
    static func playlistEntries(_ playlistId: String, completion: @escaping (Any?) -> Void) {
        post("browse", ["browseId": "VL\(playlistId)"], tag: "playlist(\(playlistId))") { json in
            completion(json?["contents"])
        }
    }

    /// Whether YouTube Music presents a channel as an artist: an artist page
    /// has a radio button, a channel that only makes videos does not. Nil
    /// when it could not be told (network).
    static func isArtist(_ channelId: String, completion: @escaping (Bool?) -> Void) {
        post("browse", ["browseId": channelId], tag: "isArtist(\(channelId))") { json in
            guard let json else {
                completion(nil)
                return
            }
            let header = (json["header"] as? [String: Any])?.values.first as? [String: Any]
            completion(header?["startRadioButton"] != nil)
        }
    }

    /// Artist and album of one song, from its own radio entry.
    static func links(
        of videoId: String,
        completion: @escaping (MusicArtistRef?, MusicAlbumRef?) -> Void
    ) {
        let known = MusicTrackLinks.links(of: videoId)
        if known.artist != nil || known.album != nil {
            completion(known.artist, known.album)
            return
        }
        watchQueue(playlistId: "RDAMVM\(videoId)", videoId: videoId) { _ in
            let found = MusicTrackLinks.links(of: videoId)
            completion(found.artist, found.album)
        }
    }

    // MARK: - Parsing

    private static func texts(_ value: Any?) -> String {
        InnertubeClient.texts(in: value as Any).joined()
    }

    private static func runs(_ value: Any?) -> [[String: Any]] {
        (value as? [String: Any])?["runs"] as? [[String: Any]] ?? []
    }

    private static func thumbnail(_ value: Any?) -> String? {
        InnertubeClient.lastThumbnailURL(in: value as Any)
    }

    private static func pageType(_ endpoint: [String: Any]?) -> String? {
        endpoint?.digString(
            "browseEndpoint", "browseEndpointContextSupportedConfigs",
            "browseEndpointContextMusicConfig", "pageType"
        )
    }

    /// Artist and album named in a byline's runs (by their page type).
    private static func bylineLinks(_ runList: [[String: Any]]) -> (MusicArtistRef?, MusicAlbumRef?) {
        var artist: MusicArtistRef?
        var album: MusicAlbumRef?
        for run in runList {
            let endpoint = run["navigationEndpoint"] as? [String: Any]
            guard let id = endpoint?.digString("browseEndpoint", "browseId"),
                  let text = run["text"] as? String
            else {
                continue
            }
            switch pageType(endpoint) {
            case "MUSIC_PAGE_TYPE_ARTIST", "MUSIC_PAGE_TYPE_USER_CHANNEL":
                if artist == nil {
                    artist = MusicArtistRef(browseId: id, name: text, subtitle: "", thumbnailURL: nil)
                }
            case "MUSIC_PAGE_TYPE_ALBUM":
                album = MusicAlbumRef(browseId: id, title: text, subtitle: "", thumbnailURL: nil)
            default:
                break
            }
        }
        return (artist, album)
    }

    /// Every list item and card in a response, in order.
    private static func listItems(in value: Any) -> [[String: Any]] {
        if let array = value as? [Any] {
            return array.flatMap { listItems(in: $0) }
        }
        guard let dict = value as? [String: Any] else {
            return []
        }
        for key in ["musicResponsiveListItemRenderer", "musicTwoRowItemRenderer"] {
            if let item = dict[key] as? [String: Any] {
                return [item]
            }
        }
        return dict.keys.sorted().flatMap { listItems(in: dict[$0] as Any) }
    }

    /// One search or shelf item, by what it opens.
    private static func entry(_ item: [String: Any]) -> MusicEntry? {
        let columns = item["flexColumns"] as? [[String: Any]] ?? []
        let columnRuns = columns.map { runs(($0["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any])?["text"]) }
        let title = item["title"] != nil ? texts(item["title"]) : columnRuns.first.map { texts(["runs": $0]) } ?? ""
        let subtitleRuns = item["subtitle"] != nil ? runs(item["subtitle"]) : Array(columnRuns.dropFirst().joined())
        // Columns read as separate facts ("Song • 3:36", "1.2B plays"); the
        // leading type word is what the section already says.
        let columnTexts = item["subtitle"] != nil
            ? [subtitleRuns.compactMap { $0["text"] as? String }.joined()]
            : columnRuns.dropFirst().map { $0.compactMap { $0["text"] as? String }.joined() }
        let subtitle = columnTexts.filter { !$0.isEmpty }.joined(separator: " · ")
            .replacingOccurrences(
                of: "^(Song|Video|Episode)\\s*•\\s*", with: "", options: .regularExpression
            )
        let thumb = thumbnail(item["thumbnail"] ?? item["thumbnailRenderer"])
        let endpoint = item["navigationEndpoint"] as? [String: Any]
        let browseId = endpoint?.digString("browseEndpoint", "browseId")
        let videoId = (item["playlistItemData"] as? [String: Any])?["videoId"] as? String
            ?? endpoint?.digString("watchEndpoint", "videoId")
        if let videoId {
            let songTitle = displayTitle(title, of: item)
            let (artist, album) = bylineLinks(subtitleRuns)
            MusicTrackLinks.note(videoId, artist: artist, album: album)
            // Album tracks keep their length in a fixed column.
            let fixed = (item["fixedColumns"] as? [Any]).map { texts($0) }
            let isLength = { (text: String) in
                text.range(of: "^\\d+:\\d{2}(:\\d{2})?$", options: .regularExpression) != nil
            }
            let duration = [fixed].compactMap { $0 }.first(where: isLength)
                ?? subtitleRuns.compactMap { ($0["text"] as? String)?.trimmingCharacters(in: .whitespaces) }
                    .first(where: isLength)
            return .song(Video(
                id: videoId,
                title: songTitle,
                channelId: artist?.browseId,
                channelName: MusicNativeNames.artist(artist?.browseId) ?? artist?.name ?? subtitle,
                channelAvatarURL: nil,
                thumbnailURL: thumb ?? "https://i.ytimg.com/vi/\(videoId)/hqdefault.jpg",
                viewCount: nil,
                publishedAt: nil,
                duration: duration
            ))
        }
        guard let browseId else {
            return nil
        }
        switch pageType(endpoint) {
        case "MUSIC_PAGE_TYPE_ARTIST":
            let name = MusicNativeNames.artist(browseId) ?? title
            return .artist(MusicArtistRef(browseId: browseId, name: name, subtitle: subtitle, thumbnailURL: thumb))
        case "MUSIC_PAGE_TYPE_ALBUM":
            let name = MusicNativeNames.album(browseId) ?? title
            return .album(MusicAlbumRef(browseId: browseId, title: name, subtitle: subtitle, thumbnailURL: thumb))
        case "MUSIC_PAGE_TYPE_PLAYLIST":
            return .playlist(Playlist(
                id: browseId.hasPrefix("VL") ? String(browseId.dropFirst(2)) : browseId,
                title: title, description: subtitle, thumbnailURL: thumb, itemCount: nil
            ))
        default:
            return nil
        }
    }

    private static func shelfTitle(_ renderer: [String: Any]) -> String {
        texts(renderer["title"] ?? renderer.digDict("header", "musicCarouselShelfBasicHeaderRenderer")?["title"])
    }

    /// The titled shelves of a section list that hold anything playable or
    /// openable (the taste builder and the like hold neither).
    private static func entryShelves(_ sections: [[String: Any]]) -> [(title: String, entries: [MusicEntry])] {
        sections.compactMap { section in
            guard let renderer = section.values.first as? [String: Any] else {
                return nil
            }
            let entries = listItems(in: renderer["contents"] as Any).compactMap(entry)
            guard !entries.isEmpty else {
                return nil
            }
            let title = shelfTitle(renderer)
            return (title.isEmpty ? "More" : title, entries)
        }
    }

    private static func parseArtist(_ json: [String: Any], browseId: String) -> MusicArtistPage? {
        let header = (json["header"] as? [String: Any])?.values.first as? [String: Any]
        let shown = texts(header?["title"])
        guard !shown.isEmpty else {
            AppLog.innertube("ytmusic artist \(browseId): no header")
            return nil
        }
        let name = MusicNativeNames.artist(browseId) ?? shown
        let play = header?.digDict("playButton", "buttonRenderer", "navigationEndpoint", "watchEndpoint")
        let radio = header?.digString(
            "startRadioButton", "buttonRenderer", "navigationEndpoint", "watchPlaylistEndpoint", "playlistId"
        )
        let artist = MusicArtistRef(browseId: browseId, name: name, subtitle: "", thumbnailURL: thumbnail(header?["thumbnail"]))
        var topSongs: [Video] = []
        var albums: [MusicAlbumRef] = []
        var singles: [MusicAlbumRef] = []
        var allShelves: [(title: String, entries: [MusicEntry])] = []
        let sections = json.digDict("contents", "singleColumnBrowseResultsRenderer")?["tabs"] as? [[String: Any]]
        let shelves = sections?.first.flatMap {
            $0.digDict("tabRenderer", "content", "sectionListRenderer")?["contents"] as? [[String: Any]]
        } ?? []
        for shelf in shelves {
            guard let renderer = shelf.values.first as? [String: Any] else {
                continue
            }
            let title = shelfTitle(renderer)
            let entries = listItems(in: renderer["contents"] as Any).compactMap(entry)
            if !entries.isEmpty {
                allShelves.append((title.isEmpty ? "More" : title, entries))
            }
            if shelf["musicShelfRenderer"] != nil {
                topSongs += entries.compactMap { entry -> Video? in
                    guard case .song(var video) = entry else {
                        return nil
                    }
                    // Top songs name only plays and the album: the artist
                    // is the page's.
                    if video.channelId == nil {
                        video.channelId = browseId
                        video.channelName = name
                        MusicTrackLinks.note(video.id, artist: artist, album: nil)
                    }
                    return video
                }
                continue
            }
            let refs = entries.compactMap { entry -> MusicAlbumRef? in
                if case .album(let ref) = entry {
                    return ref
                }
                return nil
            }
            if title.lowercased().contains("single") {
                singles += refs
            } else if title.lowercased().contains("album") {
                albums += refs
            }
        }
        AppLog.innertube(
            "ytmusic artist \(name): \(topSongs.count) songs, \(albums.count) albums, \(singles.count) singles,"
                + " shuffle=\(play?["playlistId"] as? String ?? "nil") radio=\(radio ?? "nil")"
        )
        return MusicArtistPage(
            name: name,
            thumbnailURL: artist.thumbnailURL,
            shuffle: (play?["playlistId"] as? String).map { ($0, play?["videoId"] as? String) },
            radioPlaylistId: radio,
            topSongs: topSongs,
            albums: albums,
            singles: singles,
            shelves: allShelves
        )
    }

    private static func parseAlbum(_ json: [String: Any], browseId: String) -> MusicAlbumPage? {
        let canonical = json.digString("microformat", "microformatDataRenderer", "urlCanonical")
        let playlistId = canonical
            .flatMap { URLComponents(string: $0)?.queryItems?.first { $0.name == "list" }?.value }
        // Current layout: header in the left column's first section.
        let header = firstDict(named: "musicResponsiveHeaderRenderer", in: json)
            ?? firstDict(named: "musicDetailHeaderRenderer", in: json)
        let title = texts(header?["title"])
        let subtitle = texts(header?["subtitle"])
        let artistRuns = runs(header?["straplineTextOne"]) + runs(header?["subtitle"])
        let (artist, _) = bylineLinks(artistRuns)
        let thumb = thumbnail(header?["thumbnail"])
        let album = MusicAlbumRef(browseId: browseId, title: title, subtitle: subtitle, thumbnailURL: thumb)
        let tracks = listItems(in: json["contents"] as Any).compactMap { item -> Video? in
            guard case .song(var video) = entry(item) else {
                return nil
            }
            if video.channelId == nil, let artist {
                video.channelId = artist.browseId
                video.channelName = artist.name
            }
            MusicTrackLinks.note(video.id, artist: artist, album: album)
            return video
        }
        AppLog.innertube(
            "ytmusic album \(title): \(tracks.count) tracks, playlist=\(playlistId ?? "nil"),"
                + " artist=\(artist?.name ?? "nil")"
        )
        guard !tracks.isEmpty else {
            return nil
        }
        return MusicAlbumPage(
            title: title, subtitle: subtitle, artist: artist,
            thumbnailURL: thumb, playlistId: playlistId, tracks: tracks
        )
    }

    private static func parseWatchQueue(_ json: [String: Any]) -> MusicWatchQueue {
        var panels: [[String: Any]] = []
        collect("playlistPanelVideoRenderer", in: json, into: &panels)
        let tracks = panels.compactMap { panel -> Video? in
            guard let videoId = panel["videoId"] as? String else {
                return nil
            }
            let byline = runs(panel["longBylineText"])
            let (artist, album) = bylineLinks(byline)
            MusicTrackLinks.note(videoId, artist: artist, album: album)
            return Video(
                id: videoId,
                title: displayTitle(texts(panel["title"]), of: panel),
                channelId: artist?.browseId,
                channelName: artist?.name ?? texts(panel["shortBylineText"]),
                channelAvatarURL: nil,
                thumbnailURL: thumbnail(panel["thumbnail"]) ?? "https://i.ytimg.com/vi/\(videoId)/hqdefault.jpg",
                viewCount: nil,
                publishedAt: nil,
                duration: texts(panel["lengthText"])
            )
        }
        var continuations: [[String: Any]] = []
        collect("nextRadioContinuationData", in: json, into: &continuations)
        collect("nextContinuationData", in: json, into: &continuations)
        let automix = firstDict(named: "automixPlaylistVideoRenderer", in: json)
            .flatMap { firstDict(named: "watchPlaylistEndpoint", in: $0) }
        return MusicWatchQueue(
            tracks: tracks,
            continuation: continuations.first?["continuation"] as? String,
            automix: (automix?["playlistId"] as? String).map { ($0, automix?["params"] as? String) }
        )
    }

    private static func firstString(named key: String, in value: Any) -> String? {
        if let dict = value as? [String: Any] {
            if let found = dict[key] as? String {
                return found
            }
            return dict.values.lazy.compactMap { firstString(named: key, in: $0) }.first
        }
        return (value as? [Any])?.lazy.compactMap { firstString(named: key, in: $0) }.first
    }

    // MARK: - Japanese names

    /// A song's names as YouTube Music gives them in Japanese.
    struct NativeNames {
        let title: String
        let artist: MusicArtistRef?
        let album: MusicAlbumRef?
    }

    static func hasJapanese(_ text: String) -> Bool {
        text.range(of: "[\\p{Hiragana}\\p{Katakana}\\p{Han}]", options: .regularExpression) != nil
    }

    /// In English, YouTube Music romanizes Japanese artists and albums
    /// (a romaji name for a kanji one) and names no original; only a Japanese-language
    /// answer has them, and its UI strings are Japanese too, which the
    /// parsers cannot read. So when a list has Japanese song titles (setting
    /// "Original Japanese titles"), the same request is made once more in
    /// Japanese, and only names are taken from it — by video id, and by the
    /// page type of the links, which no language changes.
    private static func nativeNames(
        of tracks: [Video],
        endpoint: String,
        body: [String: Any],
        tag: String,
        signedIn: Bool = false,
        completion: @escaping ([String: NativeNames], [String: Any]?) -> Void
    ) {
        guard OPMusicSettings.originalTitles, tracks.contains(where: { hasJapanese($0.title) }) else {
            completion([:], nil)
            return
        }
        post(endpoint, body, tag: tag, signedIn: signedIn, hl: "ja") { json in
            guard let json else {
                completion([:], nil)
                return
            }
            var names: [String: NativeNames] = [:]
            var panels: [[String: Any]] = []
            collect("playlistPanelVideoRenderer", in: json, into: &panels)
            for panel in panels {
                guard let videoId = panel["videoId"] as? String else {
                    continue
                }
                let (artist, album) = bylineLinks(runs(panel["longBylineText"]))
                names[videoId] = NativeNames(title: texts(panel["title"]), artist: artist, album: album)
            }
            for item in listItems(in: json) {
                let columns = item["flexColumns"] as? [[String: Any]] ?? []
                let columnRuns = columns.map {
                    runs(($0["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any])?["text"])
                }
                let endpoint = item["navigationEndpoint"] as? [String: Any]
                guard let videoId = (item["playlistItemData"] as? [String: Any])?["videoId"] as? String
                    ?? endpoint?.digString("watchEndpoint", "videoId"),
                    let title = columnRuns.first.map({ texts(["runs": $0]) }), !title.isEmpty
                else {
                    continue
                }
                let (artist, album) = bylineLinks(Array(columnRuns.dropFirst().joined()))
                names[videoId] = NativeNames(title: title, artist: artist, album: album)
            }
            MusicNativeNames.learn(from: json, songs: Set(tracks.filter { hasJapanese($0.title) }.map(\.id)))
            AppLog.innertube("ytmusic \(tag): \(names.count) names")
            completion(names, json)
        }
    }

    /// The track under its Japanese names, where there are any.
    /// Only a song whose English title is Japanese: a foreign song's
    /// Japanese names are katakana and translations (`MusicNativeNames.learn`).
    private static func native(_ video: Video, _ names: [String: NativeNames]) -> Video {
        guard hasJapanese(video.title), let found = names[video.id] else {
            return MusicNativeNames.renamed(video)
        }
        let links = MusicTrackLinks.links(of: video.id)
        MusicTrackLinks.note(video.id, artist: found.artist ?? links.artist, album: found.album ?? links.album)
        var renamed = Video(
            id: video.id,
            title: found.title.isEmpty ? video.title : found.title,
            channelId: video.channelId,
            channelName: found.artist?.name ?? MusicNativeNames.artist(video.channelId) ?? video.channelName,
            channelAvatarURL: video.channelAvatarURL,
            thumbnailURL: video.thumbnailURL,
            viewCount: video.viewCount,
            publishedAt: video.publishedAt,
            duration: video.duration,
            isLive: video.isLive,
            playlistId: video.playlistId,
            isShort: video.isShort
        )
        renamed.feedbackActions = video.feedbackActions
        return renamed
    }

    /// The album page with its Japanese title and artist, and its tracks'.
    private static func native(
        _ page: MusicAlbumPage, browseId: String, _ names: [String: NativeNames], header json: [String: Any]?
    ) -> MusicAlbumPage {
        guard let json else {
            return page
        }
        let header = firstDict(named: "musicResponsiveHeaderRenderer", in: json)
            ?? firstDict(named: "musicDetailHeaderRenderer", in: json)
        let title = texts(header?["title"])
        // The header's names only for a Japanese album (most English track
        // titles Japanese): a foreign one's are katakana and translations.
        guard page.tracks.filter({ hasJapanese($0.title) }).count * 2 > page.tracks.count else {
            return MusicAlbumPage(
                title: page.title, subtitle: page.subtitle, artist: page.artist,
                thumbnailURL: page.thumbnailURL, playlistId: page.playlistId,
                tracks: page.tracks.map { native($0, names) }
            )
        }
        let (artist, _) = bylineLinks(runs(header?["straplineTextOne"]) + runs(header?["subtitle"]))
        if !title.isEmpty {
            MusicNativeNames.learn(
                album: browseId, title: title, artist: artist.map { ($0.browseId, $0.name) }
            )
        }
        let pageArtist = artist ?? page.artist
        let album = MusicAlbumRef(
            browseId: browseId, title: title.isEmpty ? page.title : title, subtitle: page.subtitle,
            thumbnailURL: page.thumbnailURL
        )
        let tracks = page.tracks.map { track -> Video in
            var renamed = native(track, names)
            // Album tracks often name no artist of their own: the album's.
            if names[track.id]?.artist == nil, track.channelId == page.artist?.browseId, let pageArtist {
                renamed.channelName = pageArtist.name
            }
            MusicTrackLinks.note(track.id, artist: nil, album: album)
            return renamed
        }
        return MusicAlbumPage(
            title: album.title, subtitle: page.subtitle, artist: pageArtist,
            thumbnailURL: page.thumbnailURL, playlistId: page.playlistId, tracks: tracks
        )
    }

    /// In English, YouTube Music names a Japanese album track twice: the
    /// original, then its own romanization or translation
    /// ("<original> - <romanized>"). Only album
    /// tracks (ATV) get that; a music video's title is its uploader's and is
    /// left alone. Setting "Original Japanese titles" keeps the original.
    static func displayTitle(_ title: String, of item: [String: Any]) -> String {
        guard OPMusicSettings.originalTitles,
              firstDict(named: "watchEndpointMusicConfig", in: item)?["musicVideoType"] as? String
              == "MUSIC_VIDEO_TYPE_ATV",
              let split = title.range(of: " - ", options: .backwards)
        else {
            return title
        }
        let japanese = "[\\p{Hiragana}\\p{Katakana}\\p{Han}]"
        let original = title[..<split.lowerBound].trimmingCharacters(in: .whitespaces)
        let added = String(title[split.upperBound...])
        guard original.range(of: japanese, options: .regularExpression) != nil,
              added.range(of: japanese + "|\\p{Hangul}", options: .regularExpression) == nil
        else {
            return title
        }
        return original
    }

    private static func firstDict(named key: String, in value: Any) -> [String: Any]? {
        var found: [[String: Any]] = []
        collect(key, in: value, into: &found, limit: 1)
        return found.first
    }

    private static func collect(
        _ key: String,
        in value: Any,
        into found: inout [[String: Any]],
        limit: Int = .max
    ) {
        guard found.count < limit else {
            return
        }
        if let array = value as? [Any] {
            for element in array {
                collect(key, in: element, into: &found, limit: limit)
            }
        } else if let dict = value as? [String: Any] {
            if let match = dict[key] as? [String: Any] {
                found.append(match)
            }
            for (name, child) in dict where name != key {
                collect(key, in: child, into: &found, limit: limit)
            }
        }
    }
}
