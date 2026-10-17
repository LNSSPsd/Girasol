import UIKit

/// The Video | Music selector. The two modes are peers, so the same control
/// sits in the same place — the left of the top bar — on every root screen
/// of either one, with the active mode selected.
enum ModeSwitch {
    static func barButton() -> UIBarButtonItem {
        let control = ModeSegmentedControl(items: [
            UIImage(systemName: "play.rectangle.fill") as Any,
            UIImage(systemName: "music.note") as Any
        ])
        control.selectedSegmentIndex = MusicMode.isEnabled ? 1 : 0
        control.accessibilityLabel = "Mode"
        control.setWidth(38, forSegmentAt: 0)
        control.setWidth(38, forSegmentAt: 1)
        control.addTarget(
            control, action: #selector(ModeSegmentedControl.changed), for: .valueChanged
        )
        control.applyTheme()
        return UIBarButtonItem(customView: control)
    }
}

private final class ModeSegmentedControl: UISegmentedControl {
    func applyTheme() {
        let theme = ThemeManager.shared
        selectedSegmentTintColor = theme.accent
        setTitleTextAttributes([.foregroundColor: theme.primaryText], for: .normal)
        setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
        tintColor = theme.primaryText
    }

    @objc
    func changed() {
        Feedback.select()
        let music = selectedSegmentIndex == 1
        // Let the selection animate before the whole UI is swapped out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            MusicMode.setEnabled(music)
        }
    }
}
