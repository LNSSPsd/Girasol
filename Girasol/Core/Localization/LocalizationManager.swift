import Foundation

/// English is the only interface language (no translations ship), so every
/// string comes from the main bundle's `en.lproj`; a missing key shows as
/// itself.
extension String {
    /// Localized UI string — all user-facing text goes through this.
    var localized: String {
        Bundle.main.localizedString(forKey: self, value: self, table: nil)
    }

    /// Localized format string applied to `args`. Use positional
    /// placeholders (`%1$@`) where the order could matter.
    func localized(with args: CVarArg...) -> String {
        String(format: localized, arguments: args)
    }
}
