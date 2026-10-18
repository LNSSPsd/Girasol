// SPDX-License-Identifier: CC0-1.0
import Foundation

// MARK: - Creating and deleting playlists

/// Privacy as YouTube names it in playlist requests.
enum PlaylistPrivacy: String, CaseIterable {
    case publicList = "PUBLIC"
    case unlisted = "UNLISTED"
    case privateList = "PRIVATE"

    var title: String {
        switch self {
        case .publicList:
            return "Public"
        case .unlisted:
            return "Unlisted (link only)"
        case .privateList:
            return "Private"
        }
    }
}

extension InnertubeClient {
    /// Creates a playlist, optionally with songs in it, and answers its id.
    /// The optional web account is the one sign-in YouTube lets create
    /// playlists; without it (or refused) the TV-token attempts below run,
    /// logged, in case YouTube ever relents.
    func createPlaylist(
        title: String,
        privacy: PlaylistPrivacy,
        videoIds: [String] = [],
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        YTMusicPublic.createPlaylist(
            title: title, privacyStatus: privacy.rawValue, videoIds: videoIds
        ) { [weak self] id in
            if let id {
                completion(.success(id))
            } else if let self {
                self.createPlaylistWithTVToken(
                    title: title, privacy: privacy, videoIds: videoIds, completion: completion
                )
            } else {
                completion(.failure(APIError.invalidResponse))
            }
        }
    }

    private func createPlaylistWithTVToken(
        title: String,
        privacy: PlaylistPrivacy,
        videoIds: [String],
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let tv: [String: Any] = [
            "clientName": "TVHTML5", "clientVersion": "7.20260311.12.00", "hl": "en", "gl": "US"
        ]
        var fields: [String: Any] = ["title": title, "privacyStatus": privacy.rawValue]
        if !videoIds.isEmpty {
            fields["videoIds"] = videoIds
        }
        withValidToken(completion: completion) { client, token in
            // youtube.com answered 400 with the TV client; YouTube Music's
            // host is where the TV sign-in works for music data, so it is
            // tried next, and each refusal is logged with YouTube's reason.
            // Signed out, only the web clients answer "sign in to do this";
            // TV answers "precondition failed" — it cannot create playlists
            // at all. So the web clients go first, with the TV sign-in, and
            // TV stays as the last resort. (The YT Music apps' own token is
            // unreachable, so sending their client name cannot help.)
            let web: [String: Any] = [
                "clientName": "WEB", "clientVersion": "2.20260206.01.00", "hl": "en", "gl": "US"
            ]
            let mweb: [String: Any] = [
                "clientName": "MWEB", "clientVersion": "2.20260206.01.00", "hl": "en", "gl": "US"
            ]
            let remix: [String: Any] = [
                "clientName": "WEB_REMIX", "clientVersion": "1.20260304.03.00", "hl": "en", "gl": "US"
            ]
            client.musicPost(
                endpoint: "playlist/create",
                fields: fields,
                tag: "createPlaylist",
                targets: [
                    ("m.youtube.com", mweb), ("www.youtube.com", web),
                    ("music.youtube.com", remix), ("www.youtube.com", tv)
                ],
                token: token,
                parse: { $0["playlistId"] as? String }
            ) { result in
                guard case .failure = result else {
                    completion(result)
                    return
                }
                // Both refused: the public YouTube Data API, same token.
                Self.dataAPICreate(title: title, privacy: privacy, videoIds: videoIds, token: token, completion: completion)
            }
        }
    }

    /// `playlists.insert`, then one `playlistItems.insert` per song.
    private static func dataAPICreate(
        title: String,
        privacy: PlaylistPrivacy,
        videoIds: [String],
        token: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let status: String
        switch privacy {
        case .publicList:
            status = "public"
        case .unlisted:
            status = "unlisted"
        case .privateList:
            status = "private"
        }
        dataAPIPost(
            path: "playlists?part=snippet,status",
            body: ["snippet": ["title": title], "status": ["privacyStatus": status]],
            token: token,
            tag: "createPlaylist(data API)"
        ) { json in
            guard let id = json?["id"] as? String else {
                completion(.failure(APIError.invalidResponse))
                return
            }
            addViaDataAPI(videoIds[...], to: id, token: token) {
                completion(.success(id))
            }
        }
    }

    private static func addViaDataAPI(
        _ videoIds: ArraySlice<String>,
        to playlistId: String,
        token: String,
        done: @escaping () -> Void
    ) {
        guard let videoId = videoIds.first else {
            done()
            return
        }
        dataAPIPost(
            path: "playlistItems?part=snippet",
            body: ["snippet": [
                "playlistId": playlistId,
                "resourceId": ["kind": "youtube#video", "videoId": videoId]
            ]],
            token: token,
            tag: "addToPlaylist(data API)"
        ) { _ in
            addViaDataAPI(videoIds.dropFirst(), to: playlistId, token: token, done: done)
        }
    }

    private static func dataAPIPost(
        path: String,
        body: [String: Any],
        token: String,
        tag: String,
        completion: @escaping ([String: Any]?) -> Void
    ) {
        guard let url = URL(string: "https://www.googleapis.com/youtube/v3/\(path)") else {
            completion(nil)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            if status != 200 {
                let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                AppLog.innertube("\(tag): status=\(status) error=\(String(describing: error)) body=\(text.prefix(500))")
            } else {
                AppLog.innertube("\(tag): ok")
            }
            completion(status == 200 ? json : nil)
        }.resume()
    }

    func deletePlaylist(
        id: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        withValidToken(completion: completion) { client, token in
            var body = client.tvContext
            body["playlistId"] = id
            client.execute(
                urlString: "\(client.baseURL)\(InnertubeEndpoint.deletePlaylist)",
                body: body,
                headers: client.authHeaders(token: token),
                logTag: "deletePlaylist(\(id))"
            ) { _ -> Void? in
                // An empty 200 is the success answer.
                ()
            } completion: { completion($0) }
        }
    }

    /// Privacy goes through the same edit endpoint as title and songs.
    static func privacyAction(_ privacy: PlaylistPrivacy) -> [String: Any] {
        ["action": "ACTION_SET_PLAYLIST_PRIVACY", "playlistPrivacy": privacy.rawValue]
    }
}
