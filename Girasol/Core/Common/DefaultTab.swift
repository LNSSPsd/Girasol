import Foundation

/// The tab the app opens on. The raw value is the `UITabBarItem.tag` of the
/// matching tab — cases are declared in tab-bar order, not tag order.
enum DefaultTab: Int, CaseIterable {
    case home = 0
    case subscriptions = 1
    case library = 2

    static var available: [DefaultTab] {
        allCases
    }

    static var selected: DefaultTab {
        get {
            let raw = UserDefaults.standard.integer(
                forKey: UserDefaultsKeys.Feed.defaultTab
            )
            let stored = DefaultTab(rawValue: raw) ?? .home
            // A stored Shorts tab (gone from this fork) falls back to Home.
            return available.contains(stored) ? stored : .home
        }
        set {
            UserDefaults.standard.set(
                newValue.rawValue,
                forKey: UserDefaultsKeys.Feed.defaultTab
            )
        }
    }

    var tabTag: Int { rawValue }

    var displayName: String {
        switch self {
        case .home:
            return "home.title".localized
        case .subscriptions:
            return "subscriptions.title".localized
        case .library:
            return "library.title".localized
        }
    }
}
