import Foundation

/// Japanese names of artists and albums, by their browse id ("UC…" →
/// the artist's name, "MPREb_…" → the album's title). YouTube Music in English
/// romanizes them and names no original. Learned from every Japanese
/// answer (`YTMusicPublic.nativeNames`) and, for an artist not met yet, from
/// its artist page asked in Japanese, once; kept on the device. By id rather
/// than by video: a radio queue asked twice is two different queues, so a
/// second, Japanese copy of it names other songs.
enum MusicNativeNames {
    /// Posted (main queue) when names were learned: lists already shown and
    /// the player's queue take them over.
    static let didLearnNotification = Notification.Name("MusicNativeNamesDidLearn")

    /// "2": the first names took every link of a Japanese answer, foreign
    /// artists' katakana included; they are dropped and learned again.
    private static let artistsKey = "musicNativeNames_artists2"
    private static let albumsKey = "musicNativeNames_albums2"
    private static let lock = NSLock()
    private static var artists: [String: String] = {
        UserDefaults.standard.removeObject(forKey: "musicNativeNames_artists")
        UserDefaults.standard.removeObject(forKey: "musicNativeNames_albums")
        return UserDefaults.standard.dictionary(forKey: artistsKey) as? [String: String] ?? [:]
    }()
    private static var albums = UserDefaults.standard.dictionary(forKey: albumsKey) as? [String: String] ?? [:]
    /// Artists asked about: once each per launch, found or not.
    private static var asked: Set<String> = []

    /// Setting "Original Japanese titles".
    static var isEnabled: Bool {
        OPMusicSettings.originalTitles
    }

    static func artist(_ browseId: String?) -> String? {
        guard isEnabled, let browseId else {
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        return artists[browseId]
    }

    static func album(_ browseId: String?) -> String? {
        guard isEnabled, let browseId else {
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        return albums[browseId]
    }

    /// The track with its artist's Japanese name, when it is known.
    static func renamed(_ video: Video) -> Video {
        guard let name = artist(video.channelId), name != video.channelName else {
            return video
        }
        var renamed = video
        renamed.channelName = name
        return renamed
    }

    // MARK: - Learning

    /// The artist and album links of a Japanese answer, by page type (which
    /// no language changes), but only those of `songs`: the tracks whose
    /// English title is Japanese. In Japanese, YouTube Music writes every
    /// foreign artist in katakana and translates their titles too (an
    /// American singer's name and song titles come out in katakana),
    /// so nothing in that answer tells a Japanese song from a foreign one;
    /// the English answer does — it keeps only Japanese songs' own titles.
    static func learn(from json: Any, songs: Set<String>) {
        var found: (artists: [String: String], albums: [String: String]) = ([:], [:])
        collectLinks(in: json, japanese: false, songs: songs, into: &found)
        store(artists: found.artists, albums: found.albums)
    }

    /// A Japanese album page's own title and artist.
    static func learn(album browseId: String, title: String, artist: (browseId: String, name: String)?) {
        store(artists: artist.map { [$0.browseId: $0.name] } ?? [:], albums: [browseId: title])
    }

    /// Renderers of one song, whose video id says whether the links inside
    /// it are Japanese names.
    private static let itemRenderers: Set<String> = [
        "musicResponsiveListItemRenderer", "musicTwoRowItemRenderer", "playlistPanelVideoRenderer",
        "musicCardShelfRenderer",
    ]

    /// `japanese`: inside the item of one of `songs`.
    private static func collectLinks(
        in value: Any, japanese: Bool, songs: Set<String>,
        into found: inout (artists: [String: String], albums: [String: String])
    ) {
        if let array = value as? [Any] {
            for element in array {
                collectLinks(in: element, japanese: japanese, songs: songs, into: &found)
            }
            return
        }
        guard let dict = value as? [String: Any] else {
            return
        }
        for (key, child) in dict {
            if itemRenderers.contains(key), let item = child as? [String: Any] {
                let japanese = videoId(of: item).map { songs.contains($0) } ?? false
                collectLinks(in: item, japanese: japanese, songs: songs, into: &found)
            } else {
                collectLinks(in: child, japanese: japanese, songs: songs, into: &found)
            }
        }
        guard japanese else {
            return
        }
        if let text = dict["text"] as? String,
           let endpoint = (dict["navigationEndpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any],
           let id = endpoint["browseId"] as? String {
            let type = endpoint.digString(
                "browseEndpointContextSupportedConfigs", "browseEndpointContextMusicConfig", "pageType"
            )
            if type == "MUSIC_PAGE_TYPE_ARTIST" {
                found.artists[id] = text
            } else if type == "MUSIC_PAGE_TYPE_ALBUM" {
                found.albums[id] = text
            }
        }
    }

    /// The song an item stands for; nil for albums, playlists, artists.
    private static func videoId(of item: [String: Any]) -> String? {
        if let id = (item["playlistItemData"] as? [String: Any])?["videoId"] as? String ?? item["videoId"] as? String
            ?? item.digString("navigationEndpoint", "watchEndpoint", "videoId") {
            return id
        }
        let column = (item["flexColumns"] as? [[String: Any]])?.first?["musicResponsiveListItemFlexColumnRenderer"]
        let title = (column as? [String: Any])?["text"] ?? item["title"]
        let runs = (title as? [String: Any])?["runs"] as? [[String: Any]] ?? []
        return runs.first?.digString("navigationEndpoint", "watchEndpoint", "videoId")
    }

    private static func store(artists newArtists: [String: String], albums newAlbums: [String: String]) {
        let artists = newArtists.filter { !$0.value.isEmpty }
        let albums = newAlbums.filter { !$0.value.isEmpty }
        lock.lock()
        let changed = artists.contains { self.artists[$0.key] != $0.value }
            || albums.contains { self.albums[$0.key] != $0.value }
        self.artists.merge(artists) { $1 }
        self.albums.merge(albums) { $1 }
        let storedArtists = self.artists
        let storedAlbums = self.albums
        lock.unlock()
        guard changed else {
            return
        }
        UserDefaults.standard.set(storedArtists, forKey: artistsKey)
        UserDefaults.standard.set(storedAlbums, forKey: albumsKey)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: didLearnNotification, object: nil)
        }
    }

    // MARK: - Asking

    /// Artist ids waiting to be asked, in order.
    private static var waiting: [String] = []
    private static var isAsking = false

    /// The artists of Japanese-titled tracks not known yet: each one's
    /// artist page in Japanese, one after another, each artist once per
    /// launch.
    static func lookUp(_ tracks: [Video]) {
        guard isEnabled else {
            return
        }
        lock.lock()
        for track in tracks {
            guard let id = track.channelId, id.hasPrefix("UC"), artists[id] == nil, !asked.contains(id),
                  YTMusicPublic.hasJapanese(track.title)
            else {
                continue
            }
            asked.insert(id)
            waiting.append(id)
        }
        let start = !isAsking && !waiting.isEmpty
        isAsking = isAsking || start
        lock.unlock()
        if start {
            askNext()
        }
    }

    private static func askNext() {
        lock.lock()
        guard !waiting.isEmpty else {
            isAsking = false
            lock.unlock()
            return
        }
        let id = waiting.removeFirst()
        lock.unlock()
        YTMusicPublic.post("browse", ["browseId": id], tag: "artist ja", hl: "ja") { json in
            let header = (json?["header"] as? [String: Any])?.values.first as? [String: Any]
            let runs = (header?["title"] as? [String: Any])?["runs"] as? [[String: Any]] ?? []
            let name = runs.compactMap { $0["text"] as? String }.joined()
            AppLog.innertube("ytmusic artist \(id) in Japanese: \(name.isEmpty ? "none" : name)")
            store(artists: [id: name], albums: [:])
            askNext()
        }
    }
}

extension Video {
    /// The artist as music mode shows it: the Japanese name when it is
    /// known (`MusicNativeNames`), whichever list the song came from —
    /// playlists and history come from the TV client, which names
    /// "<Artist> - Topic" under the same channel id.
    var musicArtist: String {
        MusicNativeNames.artist(channelId) ?? channelName
    }
}
