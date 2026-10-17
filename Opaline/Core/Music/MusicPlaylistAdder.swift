import UIKit

/// "Add to playlist" for music mode. The first time in a session it asks
/// which playlist; after that it adds straight to the same one and offers
/// "Change" — which takes that copy back out and asks again. A song already
/// in the playlist is added again (a second copy). The choice lives only in
/// memory, so a fresh launch asks again.
enum MusicPlaylistAdder {
    private static var lastPlaylist: (id: String, title: String)?
    /// The playlists as last fetched for a song (with whether it is in
    /// each), kept briefly: the "…" sheet fetches them as it opens.
    private static var cached: (videoId: String, options: [PlaylistAddOption], at: Date)?
    private static var pending: [String: [([PlaylistAddOption]?) -> Void]] = [:]

    /// Starts fetching `track`'s playlists ahead of an "Add to playlist".
    static func prefetch(_ track: Video) {
        fetch(track.id) { _ in }
    }

    /// The copy the last add made, so "Change" takes out that one and not
    /// an older copy of the same song.
    private static var lastAdded: (playlistId: String, videoId: String, entryId: String?, wasThere: Bool)?

    static func add(_ track: Video, from presenter: UIViewController, anchor: UIView?) {
        guard let last = lastPlaylist else {
            options(for: track, in: presenter) { pick(track, options: $0, from: presenter, anchor: anchor) }
            return
        }
        // Straight in, again if it is there already: a second copy is asked for.
        let wasThere = cached.flatMap { $0.videoId == track.id ? $0.options.first { $0.id == last.id }?.isAdded : nil }
        insert(track, into: last, wasThere: wasThere ?? false, presenter: presenter, anchor: anchor)
    }

    private static func insert(
        _ track: Video,
        into playlist: (id: String, title: String),
        wasThere: Bool,
        presenter: UIViewController,
        anchor: UIView?
    ) {
        lastPlaylist = playlist
        cached = nil
        MusicPlaylistAPI.add(videoId: track.id, to: playlist.id) { result in
            DispatchQueue.main.async {
                guard case .success(let entryId) = result else {
                    ToastView.show("Could not change the playlist", in: presenter.view, isError: true)
                    return
                }
                lastAdded = (playlist.id, track.id, entryId, wasThere)
                MusicPlaylistEditor.post(.songs(playlist.id, 1))
                toast(
                    wasThere ? "Added to \(playlist.title) again" : "Added to \(playlist.title)",
                    change: track, presenter: presenter, anchor: anchor
                )
            }
        }
    }

    private static func pick(
        _ track: Video,
        options: [PlaylistAddOption],
        from presenter: UIViewController,
        anchor: UIView?
    ) {
        let theme = ThemeManager.shared
        let sheet = OPTrackSheet(title: "Add to playlist", subtitle: track.title)
        let artwork = ThumbnailImageView(frame: .zero)
        artwork.contentMode = .scaleAspectFill
        artwork.backgroundColor = theme.surface
        if let url = URL(string: track.thumbnailURL) {
            artwork.setImage(url: url)
        }
        sheet.artworkView = artwork
        sheet.cardColor = theme.surface
        sheet.textColor = theme.primaryText
        sheet.secondaryTextColor = theme.secondaryText
        sheet.accentColor = theme.accent
        sheet.fillColor = theme.separator
        let create = OPSheetAction(title: "New playlist", symbol: "plus", destructive: false) {
            MusicPlaylistEditViewController.present(playlist: nil, tracks: [track], from: presenter) { created in
                if let created {
                    lastPlaylist = (created.id, created.title)
                    lastAdded = nil
                    cached = nil
                    ToastView.show("Added to new playlist \(created.title)", in: presenter.view)
                }
            }
        }
        // A tick says the song is in it already; tapping adds another copy.
        let rows = options.map { option -> OPSheetAction in
            let row = OPSheetAction(title: option.title, symbol: "music.note.list", destructive: false) {
                insert(
                    track, into: (option.id, option.title), wasThere: option.isAdded,
                    presenter: presenter, anchor: anchor
                )
            }
            row.checked = option.isAdded
            return row
        }
        sheet.actions = [create] + rows
        sheet.present(from: presenter)
    }

    /// "Change": the copy just added comes out again, then the picker.
    private static func change(_ track: Video, presenter: UIViewController, anchor: UIView?) {
        guard let added = lastAdded, added.videoId == track.id,
              let action = MusicPlaylistItems.removeAction(
                  videoId: track.id, entryId: added.entryId, unique: !added.wasThere
              )
        else {
            // Which copy is the new one cannot be told: leave it, just pick.
            options(for: track, in: presenter) { pick(track, options: $0, from: presenter, anchor: anchor) }
            return
        }
        lastAdded = nil
        edit(added.playlistId, actions: [action], in: presenter) {
            MusicPlaylistEditor.post(.songs(added.playlistId, -1))
            options(for: track, in: presenter) { pick(track, options: $0, from: presenter, anchor: anchor) }
        }
    }

    private static func toast(
        _ text: String,
        change track: Video,
        presenter: UIViewController,
        anchor: UIView?
    ) {
        let theme = ThemeManager.shared
        OPActionToast.showText(
            text,
            actionTitle: "Change",
            in: presenter.view,
            bottomInset: 24,
            background: theme.surface,
            textColor: theme.primaryText,
            actionColor: theme.accent
        ) {
            change(track, presenter: presenter, anchor: anchor)
        }
    }

    // MARK: - Requests

    private static func options(
        for track: Video,
        in presenter: UIViewController,
        completion: @escaping ([PlaylistAddOption]) -> Void
    ) {
        fetch(track.id) { options in
            guard let options, !options.isEmpty else {
                ToastView.show("Could not load your playlists", in: presenter.view, isError: true)
                return
            }
            completion(options)
        }
    }

    /// The cached list when it is under a minute old, else one request
    /// shared by everyone waiting for it. Main queue.
    private static func fetch(_ videoId: String, completion: @escaping ([PlaylistAddOption]?) -> Void) {
        if let cached, cached.videoId == videoId, Date().timeIntervalSince(cached.at) < 60 {
            completion(cached.options)
            return
        }
        guard pending[videoId] == nil else {
            pending[videoId]?.append(completion)
            return
        }
        pending[videoId] = [completion]
        MusicPlaylistAPI.addOptions(videoId: videoId) { result in
            DispatchQueue.main.async {
                let options = try? result.get()
                if let options {
                    cached = (videoId, options, Date())
                }
                let waiting = pending.removeValue(forKey: videoId) ?? []
                waiting.forEach { $0(options) }
            }
        }
    }

    private static func edit(
        _ playlistId: String,
        actions: [[String: Any]],
        in presenter: UIViewController,
        done: @escaping () -> Void
    ) {
        // Whatever happens, the cached ticks may be wrong now.
        cached = nil
        MusicPlaylistAPI.edit(playlistId: playlistId, actions: actions) { result in
            DispatchQueue.main.async {
                guard case .success = result else {
                    ToastView.show("Could not change the playlist", in: presenter.view, isError: true)
                    return
                }
                done()
            }
        }
    }
}
