import UIKit

/// What changed in the user's playlists, for screens that show them
/// before YouTube's own lists catch up (they lag a few seconds).
enum MusicPlaylistChange {
    case created(Playlist)
    case deleted(String)
    /// Songs added (positive) or removed (negative).
    case songs(String, Int)
}

/// Creating, deleting and setting the privacy of the user's playlists.
enum MusicPlaylistEditor {
    /// Posted after a playlist changed, with the `MusicPlaylistChange` in
    /// userInfo["change"], so the library reloads and shows it meanwhile.
    static let didChangeNotification = Notification.Name("MusicPlaylistsDidChange")

    static func post(_ change: MusicPlaylistChange) {
        if case .deleted(let id) = change {
            // Speed dial must not keep offering it.
            MusicPlayLog.shared.forgetCollection(id)
        }
        NotificationCenter.default.post(name: didChangeNotification, object: nil, userInfo: ["change": change])
    }

    /// Only the optional web sign-in can create playlists, so without it
    /// the failure says where to get one.
    static var createFailureMessage: String {
        OPMusicWebAccount.signedIn
            ? "Could not create the playlist"
            : "Creating playlists needs the YouTube Music sign-in: Music settings (⚙︎) → Sign in"
    }

    /// Name, then privacy, then created — with `track` in it when given.
    static func create(
        adding track: Video? = nil,
        from presenter: UIViewController,
        anchor: UIView?,
        completion: ((Playlist) -> Void)? = nil
    ) {
        let alert = UIAlertController(title: "New playlist", message: nil, preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "Title" }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Next", style: .default) { [weak alert] _ in
            let title = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !title.isEmpty else {
                return
            }
            choosePrivacy(title: "Who can see \"\(title)\"?", from: presenter, anchor: anchor) { privacy in
                ServiceContainer.music.createPlaylist(
                    title: title,
                    privacy: privacy,
                    videoIds: track.map { [$0.id] } ?? []
                ) { result in
                    DispatchQueue.main.async {
                        guard case .success(let id) = result else {
                            ToastView.show(createFailureMessage, in: presenter.view, isError: true)
                            return
                        }
                        AppLog.player("music: created playlist \(id) (\(privacy.rawValue))")
                        ToastView.show(
                            track == nil ? "Created \(title)" : "Added to new playlist \(title)",
                            in: presenter.view
                        )
                        let created = Playlist(
                            id: id, title: title, description: privacy.title,
                            thumbnailURL: nil, itemCount: track == nil ? 0 : 1
                        )
                        post(.created(created))
                        completion?(created)
                    }
                }
            }
        })
        presenter.present(alert, animated: true)
    }

    static func setPrivacy(of playlist: Playlist, from presenter: UIViewController, anchor: UIView?) {
        choosePrivacy(title: "Who can see \"\(playlist.title)\"?", from: presenter, anchor: anchor) { privacy in
            MusicPlaylistAPI.edit(
                playlistId: playlist.id,
                actions: [InnertubeClient.privacyAction(privacy)]
            ) { result in
                DispatchQueue.main.async {
                    if case .success = result {
                        ToastView.show("Now \(privacy.title.lowercased())", in: presenter.view)
                    } else {
                        ToastView.show("Could not change who can see it", in: presenter.view, isError: true)
                    }
                }
            }
        }
    }

    static func delete(
        _ playlist: Playlist,
        from presenter: UIViewController,
        anchor: UIView?,
        completion: (() -> Void)? = nil
    ) {
        let sheet = UIAlertController(
            title: "Delete \"\(playlist.title)\"?",
            message: "This deletes it on YouTube for good.",
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: "Delete playlist", style: .destructive) { _ in
            MusicPlaylistAPI.delete(id: playlist.id) { result in
                DispatchQueue.main.async {
                    guard case .success = result else {
                        ToastView.show("Could not delete it", in: presenter.view, isError: true)
                        return
                    }
                    ToastView.show("Deleted \(playlist.title)", in: presenter.view)
                    post(.deleted(playlist.id))
                    completion?()
                }
            }
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        MusicTrackMenu.present(sheet, from: presenter, anchor: anchor)
    }

    static func choosePrivacy(
        title: String,
        from presenter: UIViewController,
        anchor: UIView?,
        chosen: @escaping (PlaylistPrivacy) -> Void
    ) {
        let sheet = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
        for privacy in PlaylistPrivacy.allCases {
            sheet.addAction(UIAlertAction(title: privacy.title, style: .default) { _ in
                chosen(privacy)
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        MusicTrackMenu.present(sheet, from: presenter, anchor: anchor)
    }
}
