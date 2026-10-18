// SPDX-License-Identifier: CC0-1.0
import UIKit

/// The app-wide switch between Opaline's video UI and music mode: a music
/// library and player with nothing video in it. Persisted, so the app comes
/// back in whichever mode it was left in.
enum MusicMode {
    private static let key = "musicMode_enabled"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: key)
    }

    /// Rebuilds the window's UI for the new mode. What the other mode was
    /// playing goes on, shown small (the song's bar, the video's picture),
    /// until something is opened here — the two share one audio session.
    static func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else {
            return
        }
        AppLog.player("music mode \(enabled ? "on" : "off")")
        if enabled {
            VideoRouter.shared.minimize()
        } else if !MusicPlayer.shared.isActive {
            AudioOnlyMode.isEnabled = false
            AudioOnlyMode.soundOnly = false
        }
        UserDefaults.standard.set(enabled, forKey: key)
        (UIApplication.shared.delegate as? AppDelegate)?.showMain()
    }
}
