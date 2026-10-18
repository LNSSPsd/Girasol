// SPDX-License-Identifier: CC0-1.0
import UIKit

/// Spotify's share sheet hands its "Give this playlist a listen: …" text
/// only to the apps it knows. Its "Copy link" does work: coming back to
/// the app with a Spotify playlist link copied offers to open it, once per
/// copy. The pasteboard is only read when iOS says it holds a link
/// (`detectPatterns` shows no paste banner).
enum MusicSpotifyClipboard {
    private static var offeredChangeCount = -1

    static func start() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            // After a cold start the splash is still the root for a moment.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { check() }
        }
    }

    private static func check() {
        let pasteboard = UIPasteboard.general
        guard pasteboard.changeCount != offeredChangeCount, pasteboard.hasStrings else {
            return
        }
        let changeCount = pasteboard.changeCount
        pasteboard.detectPatterns(for: [.probableWebURL]) { result in
            guard case .success(let patterns) = result, patterns.contains(.probableWebURL) else {
                return
            }
            DispatchQueue.main.async {
                guard pasteboard.changeCount == changeCount, offeredChangeCount != changeCount else {
                    return
                }
                offeredChangeCount = changeCount
                guard let id = playlistId(in: pasteboard.string ?? "") else {
                    return
                }
                offer(id)
            }
        }
    }

    private static func playlistId(in text: String) -> String? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        return detector?.matches(in: text, options: [], range: range)
            .lazy.compactMap { $0.url.flatMap(YouTubeLinkParser.spotifyPlaylistId) }.first
    }

    private static func offer(_ playlistId: String) {
        guard let view = (UIApplication.shared.delegate as? AppDelegate)?.window?.rootViewController?.view else {
            return
        }
        AppLog.player("spotify playlist \(playlistId) on the clipboard: offered")
        let theme = ThemeManager.shared
        OPActionToast.showText(
            "Spotify playlist copied",
            actionTitle: "Open",
            in: view,
            bottomInset: 120,
            background: theme.surface,
            textColor: theme.primaryText,
            actionColor: theme.accent
        ) {
            MusicNavigator.openSpotifyPlaylist(playlistId)
        }
    }
}
