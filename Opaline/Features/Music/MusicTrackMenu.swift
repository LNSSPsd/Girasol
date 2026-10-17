import UIKit

/// The "…" menu of a song: queue, playlists, like, download.
enum MusicTrackMenu {
    /// The context a song was opened from, when it is a playlist of yours:
    /// which row it is, so removing takes out that copy and no other.
    struct OwnPlaylist {
        let id: String
        let title: String
        /// The row's entry id (`setVideoId`), when known.
        let entryId: String?
        /// The song is in the playlist only once.
        let unique: Bool
        let onRemoved: () -> Void
    }

    static func show(
        for track: Video,
        from presenter: UIViewController,
        anchor: UIView?,
        ownPlaylist: OwnPlaylist? = nil
    ) {
        let theme = ThemeManager.shared
        let sheet = OPTrackSheet(title: track.title, subtitle: track.musicArtist)
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
        sheet.onSubtitleTap = {
            MusicNavigator.open(.artist, of: track, from: presenter)
        }
        let downloaded = MusicDownloads.state(of: track.id) != .none
        sheet.toggles = [
            OPSheetToggle(
                title: "Like", onTitle: "Liked",
                symbol: "hand.thumbsup", onSymbol: "hand.thumbsup.fill",
                on: MusicLikes.isLiked(track.id)
            ) { liked in
                MusicLikes.set(track.id, liked: liked) { ok in
                    if !ok {
                        ToastView.show("Could not change the like", in: presenter.view, isError: true)
                    }
                }
            },
            OPSheetToggle(
                title: "Download", onTitle: "Downloaded",
                symbol: "arrow.down.circle", onSymbol: "arrow.down.circle.fill",
                on: downloaded
            ) { on in
                if on {
                    MusicDownloads.download([track])
                } else {
                    MusicDownloads.remove([track])
                }
            }
        ]
        var actions = [
            OPSheetAction(title: "Play next", symbol: "text.insert", destructive: false) {
                MusicPlayer.shared.playNext(track)
                ToastView.show("Plays next", in: presenter.view)
            },
            OPSheetAction(title: "Add to end of queue", symbol: "text.append", destructive: false) {
                MusicPlayer.shared.addToQueue(track)
                ToastView.show("Added to the end of the queue", in: presenter.view)
            },
            OPSheetAction(title: "Add to playlist", symbol: "text.badge.plus", destructive: false) {
                MusicPlaylistAdder.add(track, from: presenter, anchor: anchor)
            },
            OPSheetAction(title: "View queue", symbol: "list.bullet", destructive: false) {
                showQueue(from: presenter)
            },
            OPSheetAction(title: "Go to album", symbol: "square.stack", destructive: false) {
                MusicNavigator.open(.album, of: track, from: presenter)
            },
            OPSheetAction(title: "Go to artist", symbol: "person", destructive: false) {
                MusicNavigator.open(.artist, of: track, from: presenter)
            }
        ]
        if let ownPlaylist {
            actions.append(OPSheetAction(
                title: "Remove from \(ownPlaylist.title)", symbol: "minus.circle", destructive: true
            ) {
                removeFromPlaylist(track, ownPlaylist, presenter: presenter)
            })
        }
        sheet.actions = actions
        sheet.present(from: presenter)
        // Ready by the time "Add to playlist" is tapped.
        MusicPlaylistAdder.prefetch(track)
    }

    static func showQueue(from presenter: UIViewController) {
        presenter.present(
            RotatingNavigationController(rootViewController: MusicQueueViewController()),
            animated: true
        )
    }

    static func removeFromPlaylist(
        _ track: Video,
        _ playlist: OwnPlaylist,
        presenter: UIViewController
    ) {
        guard let action = MusicPlaylistItems.removeAction(
            videoId: track.id, entryId: playlist.entryId, unique: playlist.unique
        ) else {
            // A copy of a song that is in there twice, with no entry id to
            // say which: removing by video id could take out the other one.
            ToastView.show(
                "Can't tell this copy from the other one — sign in to YouTube Music to remove it",
                in: presenter.view, isError: true
            )
            return
        }
        MusicPlaylistAPI.edit(playlistId: playlist.id, actions: [action]) { result in
            DispatchQueue.main.async {
                guard case .success = result else {
                    ToastView.show("Could not remove it", in: presenter.view, isError: true)
                    return
                }
                ToastView.show("Removed from \(playlist.title)", in: presenter.view)
                MusicPlaylistEditor.post(.songs(playlist.id, -1))
                playlist.onRemoved()
            }
        }
    }

    /// Action sheets need an anchor on iPad.
    static func present(_ sheet: UIAlertController, from presenter: UIViewController, anchor: UIView?) {
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = anchor ?? presenter.view
            popover.sourceRect = anchor?.bounds
                ?? CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
        }
        presenter.present(sheet, animated: true)
    }
}
