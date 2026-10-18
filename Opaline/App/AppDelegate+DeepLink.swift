import UIKit

/// Handles `ytlite://` and youtube.com links passed to the app via
/// `application(_:open:options:)`. The pre-scene, single-window
/// `AppDelegate` hook is correct here (see `CLAUDE.md`: no scene delegates,
/// iOS 12 is the primary target).
extension AppDelegate {
    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        guard YouTubeLinkParser.handles(url) else {
            return false
        }
        // Music mode's root is its own tab bar; a Spotify playlist opens
        // there from either mode.
        let root = window?.rootViewController
        if let spotify = YouTubeLinkParser.spotifyPlaylistId(from: url),
           root is RootContainerViewController || root is MusicTabBarController {
            MusicNavigator.openSpotifyPlaylist(spotify)
            return true
        }
        guard root is RootContainerViewController else {
            // Splash/auth still up — replay once showMain() runs.
            pendingDeepLink = url
            return true
        }
        openVideo(from: url)
        return true
    }

    func replayPendingDeepLinkIfNeeded() {
        guard let url = pendingDeepLink else {
            return
        }
        pendingDeepLink = nil
        openVideo(from: url)
    }

    private func openVideo(from url: URL) {
        if let spotify = YouTubeLinkParser.spotifyPlaylistId(from: url) {
            MusicNavigator.openSpotifyPlaylist(spotify)
            return
        }
        let playlistId = YouTubeLinkParser.playlistId(from: url)
        let videoOrMixSeed = YouTubeLinkParser.videoId(from: url)
            ?? YouTubeLinkParser.mixSeedVideoId(from: url)
        guard let videoId = videoOrMixSeed else {
            // A real playlist, with a page of its own to show.
            playlistId.map(VideoRouter.shared.openPlaylistId)
            return
        }
        VideoRouter.shared.openVideoId(
            videoId,
            startAt: YouTubeLinkParser.startSeconds(from: url),
            isShort: YouTubeLinkParser.isShort(url),
            playlistId: playlistId
        )
    }
}
