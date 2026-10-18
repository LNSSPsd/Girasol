import UIKit

// MARK: - Region
//
// Innertube `gl` (region gating). The content language (`hl`) follows the
// device's language (`AppLanguage.effective`); the interface is English.
// "System" clears the stored region; changes fully apply after an app
// restart, and the feed cache is dropped so stale pages never resurface.

extension SettingsViewController {
    /// Curated `gl` options.
    private static let regions = [
        "US", "RU", "UA", "DE", "FR", "ES", "PT", "BR", "IT", "PL",
        "TR", "JP", "KR", "TW", "IN", "ID", "VN", "SA", "TH", "GB", "CA"
    ]

    /// Region names from iOS's built-in catalog, in English like the rest
    /// of the interface.
    private var namesLocale: Locale {
        Locale(identifier: "en")
    }

    // MARK: Cells

    func makeRegionCell() -> UITableViewCell {
        makeDisclosureCell(
            "settings.row.region".localized,
            value: storedValueDisplay(
                key: UserDefaultsKeys.Localization.region,
                systemValue: InnertubeContexts.localePreferences.gl,
                name: regionName
            )
        )
    }

    // MARK: Selection

    func handleLanguageSelection(_ row: Row) -> Bool {
        switch row {
        case .region:
            showRegionPicker()
        default:
            return false
        }
        return true
    }

    // MARK: - Private

    /// "Name" when overridden, "System (xx)" when following the device.
    private func storedValueDisplay(
        key: String,
        systemValue: String,
        name: (String) -> String
    ) -> String {
        if let stored = UserDefaults.standard.string(forKey: key) {
            return name(stored)
        }
        return "settings.language.system".localized + " (\(systemValue))"
    }

    private func regionName(_ code: String) -> String {
        namesLocale.localizedString(forRegionCode: code) ?? code
    }

    private func showRegionPicker() {
        let options = [(nil, "settings.language.system".localized)]
            + Self.regions.map { ($0 as String?, regionName($0)) }
        presentCodePicker(
            title: "settings.row.region".localized,
            options: options,
            selected: UserDefaults.standard.string(
                forKey: UserDefaultsKeys.Localization.region
            )
        ) { code in
            UserDefaults.standard.set(
                code, forKey: UserDefaultsKeys.Localization.region
            )
            AppCache.shared.clearAllDiskCache()
        }
    }

    /// Shared sheet: "System" + curated codes, checkmark on the current
    /// pick, restart alert after a change.
    private func presentCodePicker(
        title: String,
        options: [(String?, String)],
        selected: String?,
        onPick: @escaping (String?) -> Void
    ) {
        let sheet = UIAlertController(
            title: title, message: nil, preferredStyle: .actionSheet
        )
        for (code, name) in options {
            let action = UIAlertAction(
                title: name, style: .default
            ) { [weak self] _ in
                onPick(code)
                self?.reloadAllSettings()
                self?.presentSimpleAlert(
                    title: "settings.language.restartTitle".localized,
                    message: "settings.language.restartMessage".localized
                )
            }
            if code == selected {
                action.setValue(true, forKey: "checked")
            }
            sheet.addAction(action)
        }
        sheet.addAction(
            UIAlertAction(title: "common.cancel".localized, style: .cancel)
        )
        configureCenteredPopover(sheet)
        present(sheet, animated: true)
    }
}
