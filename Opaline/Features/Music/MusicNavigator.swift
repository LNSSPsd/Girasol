// SPDX-License-Identifier: CC0-1.0
import UIKit

/// Opens artist and album pages from anywhere in music mode — the player
/// sheet included: it closes the sheet and pushes onto the tab underneath.
enum MusicNavigator {
    static func openArtist(_ artist: MusicArtistRef, from presenter: UIViewController) {
        push(MusicArtistViewController(artist: artist), from: presenter)
    }

    static func openAlbum(_ album: MusicAlbumRef, from presenter: UIViewController) {
        push(MusicCollectionViewController(album: album), from: presenter)
    }

    /// A shared Spotify playlist, from a link: in music mode (switched to
    /// when the app is in video mode), on the tab showing.
    static func openSpotifyPlaylist(_ playlistId: String) {
        if !MusicMode.isEnabled {
            MusicMode.setEnabled(true)
        }
        let root = (UIApplication.shared.delegate as? AppDelegate)?.window?.rootViewController
        guard let tabs = root as? MusicTabBarController,
              let nav = tabs.selectedViewController as? UINavigationController
        else {
            return
        }
        let page = MusicSpotifyViewController(playlistId: playlistId)
        if tabs.presentedViewController != nil {
            tabs.dismiss(animated: true) {
                nav.pushViewController(page, animated: true)
            }
        } else {
            nav.pushViewController(page, animated: true)
        }
    }

    /// Resolves a song's artist or album (known links first, else its radio
    /// entry), then opens it.
    static func open(_ target: Target, of track: Video, from presenter: UIViewController) {
        YTMusicPublic.links(of: track.id) { artist, album in
            DispatchQueue.main.async {
                switch target {
                case .artist:
                    if let artist {
                        openArtist(artist, from: presenter)
                    } else {
                        ToastView.show("No artist page for this song", in: presenter.view, isError: true)
                    }
                case .album:
                    if let album {
                        openAlbum(album, from: presenter)
                    } else {
                        findAlbum(of: track, from: presenter)
                    }
                }
            }
        }
    }

    /// A music video names no album: the same song in the song search does.
    private static func findAlbum(of track: Video, from presenter: UIViewController) {
        let query = "\(track.title) \(track.channelName)"
        YTMusicPublic.search(query, filter: YTMusicPublic.searchFilters[0].params) { entries in
            let album = entries.lazy.compactMap { entry -> MusicAlbumRef? in
                guard case .song(let song) = entry else {
                    return nil
                }
                return MusicTrackLinks.links(of: song.id).album
            }.first
            guard let album else {
                ToastView.show("Could not find this song's album", in: presenter.view, isError: true)
                return
            }
            MusicTrackLinks.note(track.id, artist: nil, album: album)
            openAlbum(album, from: presenter)
        }
    }

    enum Target {
        case artist, album
    }

    private static func push(_ page: UIViewController, from presenter: UIViewController) {
        if let nav = presenter.navigationController, nav.tabBarController != nil {
            nav.pushViewController(page, animated: true)
            return
        }
        // From a sheet (the player, Up next): back to the tabs, then push.
        let root = (UIApplication.shared.delegate as? AppDelegate)?.window?.rootViewController
        guard let tabs = root as? MusicTabBarController,
              let nav = tabs.selectedViewController as? UINavigationController
        else {
            return
        }
        tabs.dismiss(animated: true) {
            nav.pushViewController(page, animated: true)
        }
    }
}
