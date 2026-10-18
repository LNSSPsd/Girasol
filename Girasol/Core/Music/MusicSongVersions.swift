// SPDX-License-Identifier: CC0-1.0
import Foundation

/// Plays songs, not their music videos. YouTube Music lists a track's
/// music video where one exists — on album pages, in play queues, in
/// search — and an MV can differ from the album version (a radio edit, an
/// intro, a skit). The song version is YouTube's own data, not a guess:
/// the same album playlist on youtube.com lists the "Artist - Topic" song
/// upload at the place YouTube Music puts the MV.
///
/// Albums are swapped whole as they open; any other track — from a
/// playlist, an artist page, search, radio — is checked by the player just
/// before it plays, through its album (its position on YouTube Music's page
/// → the same position on youtube.com). Results are kept on disk; "" means
/// it has no other version.
enum MusicSongVersions {
    /// "2": builds before MV-only album copies were known cached their
    /// music videos as having no song version.
    private static let cacheKey = "musicSongVersions2"
    private static var cache: [String: String] = UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: String] ?? [:]
    private static var waiting: [String: [(Video?) -> Void]] = [:]

    static var isEnabled: Bool {
        OPMusicSettings.songVersions
    }

    /// The song version already known for `track`, without asking.
    static func known(_ track: Video) -> Video? {
        guard isEnabled, let id = cache[track.id], !id.isEmpty else {
            return nil
        }
        return track.withId(id, duration: YTMusicPublic.songLength(of: id))
    }

    /// The song version's id when one is known, setting or not: a
    /// downloaded song version stands for its music video.
    static func songId(of videoId: String) -> String? {
        cache[videoId].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Whether `track` was looked up already (with or without a result).
    static func isResolved(_ track: Video) -> Bool {
        cache[track.id] != nil
    }

    /// An album's tracks with each music video swapped for the song at the
    /// same place on youtube.com — only when both lists are the same album
    /// (same length). `title` finds the real album when this playlist is
    /// its music-video copy. Main queue.
    static func albumTracks(_ tracks: [Video], playlistId: String, title: String, completion: @escaping ([Video]) -> Void) {
        guard isEnabled, playlistId.hasPrefix("OLAK"), !tracks.isEmpty else {
            completion(tracks)
            return
        }
        YTMusicPublic.albumSongIds(playlistId: playlistId) { ids in
            DispatchQueue.main.async {
                guard let ids, ids.count == tracks.count else {
                    AppLog.player("music: song versions of \(playlistId): lists differ (\(ids?.count ?? -1) vs \(tracks.count)), kept")
                    completion(tracks)
                    return
                }
                guard ids == tracks.map(\.id) else {
                    swap(tracks, to: ids, playlistId: playlistId, completion: completion)
                    return
                }
                // Same list on youtube.com: songs already, or a copy of the
                // album made of its music videos.
                songAlbum(of: tracks, playlistId: playlistId, title: title) { songIds in
                    swap(tracks, to: songIds ?? ids, playlistId: playlistId, completion: completion)
                }
            }
        }
    }

    private static func swap(_ tracks: [Video], to ids: [String], playlistId: String, completion: @escaping ([Video]) -> Void) {
        let swapped = zip(tracks, ids).map { track, id in id == track.id ? track : track.withId(id, duration: YTMusicPublic.songLength(of: id)) }
        for (track, id) in zip(tracks, ids) {
            remember(track.id, id == track.id ? "" : id)
            remember(id, "")
        }
        save()
        let count = zip(tracks, ids).filter { $0.id != $1 }.count
        AppLog.player("music: song versions of \(playlistId): \(count) of \(tracks.count) music videos swapped")
        completion(swapped)
    }

    /// The song ids of the album `tracks` are a music-video copy of. Some
    /// albums have a second `OLAK…` playlist of only their MVs, listed the
    /// same on youtube.com and linked to no album page; the real album's
    /// YouTube Music page lists those very MVs, under its own playlist.
    /// Found by searching the title and accepted only when that page lists
    /// exactly the same videos. Checked once per playlist ("" = it is the
    /// album itself, or none found). Main queue.
    private static func songAlbum(of tracks: [Video], playlistId: String, title: String, completion: @escaping ([String]?) -> Void) {
        if let known = cache[playlistId] {
            guard !known.isEmpty else {
                completion(nil)
                return
            }
            YTMusicPublic.albumSongIds(playlistId: known) { ids in
                DispatchQueue.main.async {
                    completion(ids.flatMap { $0.count == tracks.count ? $0 : nil })
                }
            }
            return
        }
        let finish: (String, [String]?) -> Void = { songPlaylist, ids in
            DispatchQueue.main.async {
                if ids != nil || songPlaylist.isEmpty {
                    remember(playlistId, songPlaylist)
                    save()
                }
                completion(ids)
            }
        }
        let artist = tracks[0].channelName.replacingOccurrences(of: " - Topic", with: "")
        guard !title.isEmpty else {
            finish("", nil)
            return
        }
        YTMusicPublic.search("\(title) \(artist)", filter: YTMusicPublic.searchFilters[1].params) { entries in
            let albums = entries.compactMap { entry -> MusicAlbumRef? in
                guard case .album(let album) = entry, normalized(album.title) == normalized(title) else {
                    return nil
                }
                return album
            }
            check(albums.prefix(2).map { $0 }, tracks: tracks, playlistId: playlistId, finish: finish)
        }
    }

    private static func check(_ albums: [MusicAlbumRef], tracks: [Video], playlistId: String, finish: @escaping (String, [String]?) -> Void) {
        guard let album = albums.first else {
            finish("", nil)
            return
        }
        YTMusicPublic.album(album.browseId) { page in
            guard let page, let songPlaylist = page.playlistId, songPlaylist != playlistId,
                  page.tracks.map(\.id) == tracks.map(\.id)
            else {
                check(Array(albums.dropFirst()), tracks: tracks, playlistId: playlistId, finish: finish)
                return
            }
            YTMusicPublic.albumSongIds(playlistId: songPlaylist) { ids in
                guard let ids, ids.count == tracks.count else {
                    finish(songPlaylist, nil)
                    return
                }
                // A twin listing the same songs: nothing to swap.
                guard ids != tracks.map(\.id) else {
                    finish("", nil)
                    return
                }
                AppLog.player("music: \(playlistId) is the music videos of \(album.title) (\(songPlaylist))")
                finish(songPlaylist, ids)
            }
        }
    }

    /// The song version of one track, through its album; nil when it has
    /// none or it cannot be told. Main queue.
    static func resolve(_ track: Video, completion: @escaping (Video?) -> Void) {
        guard isEnabled else {
            completion(nil)
            return
        }
        if let id = cache[track.id] {
            completion(id.isEmpty ? nil : track.withId(id, duration: YTMusicPublic.songLength(of: id)))
            return
        }
        guard waiting[track.id] == nil else {
            waiting[track.id]?.append(completion)
            return
        }
        waiting[track.id] = [completion]
        let finish: (String) -> Void = { id in
            DispatchQueue.main.async {
                remember(track.id, id)
                save()
                let result = id.isEmpty ? nil : track.withId(id, duration: YTMusicPublic.songLength(of: id))
                (waiting.removeValue(forKey: track.id) ?? []).forEach { $0(result) }
            }
        }
        YTMusicPublic.links(of: track.id) { _, album in
            if let album {
                song(of: track, on: album, exactly: false, finish: finish)
                return
            }
            // A music video names no album. The song search names the
            // albums it may be on; one counts only when its page lists this
            // very video (a namesake's album does not).
            YTMusicPublic.search("\(track.title) \(track.channelName)", filter: YTMusicPublic.searchFilters[0].params) { entries in
                var albums: [MusicAlbumRef] = []
                for case .song(let song) in entries {
                    if let album = MusicTrackLinks.links(of: song.id).album,
                       !albums.contains(where: { $0.browseId == album.browseId }) {
                        albums.append(album)
                    }
                }
                songOnAlbums(of: track, albums: Array(albums.prefix(3)), finish: finish)
            }
        }
    }

    private static func songOnAlbums(of track: Video, albums: [MusicAlbumRef], finish: @escaping (String) -> Void) {
        guard let album = albums.first else {
            finish("")
            return
        }
        YTMusicPublic.album(album.browseId) { page in
            guard let page, page.tracks.contains(where: { $0.id == track.id }) else {
                songOnAlbums(of: track, albums: Array(albums.dropFirst()), finish: finish)
                return
            }
            MusicTrackLinks.note(track.id, artist: nil, album: album)
            song(of: track, on: album, page: page, exactly: true, finish: finish)
        }
    }

    /// The song at `track`'s place on `album`, through youtube.com.
    /// `exactly`: only as itself, not by title.
    private static func song(of track: Video, on album: MusicAlbumRef, page known: MusicAlbumPage? = nil,
                             exactly: Bool, finish: @escaping (String) -> Void) {
        let found: (MusicAlbumPage?) -> Void = { page in
            guard let page, let playlistId = page.playlistId,
                  let index = exactly ? page.tracks.firstIndex(where: { $0.id == track.id }) : position(of: track, in: page.tracks)
            else {
                finish("")
                return
            }
            YTMusicPublic.albumSongIds(playlistId: playlistId) { ids in
                // The album page's own entry when the lists differ and
                // it is not the music video itself.
                let id = ids.flatMap { $0.count == page.tracks.count ? $0[index] : nil } ?? page.tracks[index].id
                AppLog.player("music: song version of \(track.id): \(id) (\(album.title) #\(index + 1))")
                finish(id == track.id ? "" : id)
            }
        }
        if let known {
            found(known)
        } else {
            YTMusicPublic.album(album.browseId, completion: found)
        }
    }

    /// Where `track` sits on its own album: as itself (the page lists the
    /// music video), else the one track of exactly that title (the page
    /// lists the song, and the video came from elsewhere). Several or no
    /// matches: unknown — a wrong song is worse than the video.
    private static func position(of track: Video, in tracks: [Video]) -> Int? {
        if let index = tracks.firstIndex(where: { $0.id == track.id }) {
            return index
        }
        let title = normalized(track.title)
        let matches = tracks.indices.filter { normalized(tracks[$0].title) == title }
        return !title.isEmpty && matches.count == 1 ? matches[0] : nil
    }

    private static func normalized(_ title: String) -> String {
        title.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func remember(_ videoId: String, _ songId: String) {
        cache[videoId] = songId
    }

    private static func save() {
        UserDefaults.standard.set(cache, forKey: cacheKey)
    }
}

extension Video {
    /// The same track under another video id (its song version). The MV's
    /// length is not the song's: `duration` is the song's own, when known.
    func withId(_ id: String, duration: String? = nil) -> Video {
        var copy = Video(
            id: id,
            title: title,
            channelId: channelId,
            channelName: channelName,
            channelAvatarURL: channelAvatarURL,
            thumbnailURL: thumbnailURL,
            viewCount: viewCount,
            publishedAt: publishedAt,
            duration: duration,
            isLive: isLive,
            playlistId: playlistId,
            isShort: isShort
        )
        copy.feedbackActions = feedbackActions
        return copy
    }
}
