import UIKit

/// The one-tap import from Opaline (`OPOpalineImport`): offered once when
/// Girasol first starts with Opaline on the phone, and from Settings any
/// time after. The import replaces what the app holds in memory, so Girasol
/// closes when it is done and says what came over at the next start.
enum OpalineImportPrompt {
    private static let offeredKey = "opalineImport.offered"
    private static let resultKey = "opalineImport.result"

    /// Whether Settings shows the row: an unsandboxed build, with Opaline
    /// installed.
    static var isAvailable: Bool {
        OPOpalineImport.opalineContainer != nil
    }

    /// At launch, once the first real screen is up: the result of an import
    /// that just closed the app, or the offer, the first time only.
    static func launched(in window: UIWindow?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard let window, let top = topViewController(of: window) else {
                return
            }
            let defaults = UserDefaults.standard
            if let result = defaults.string(forKey: resultKey) {
                defaults.removeObject(forKey: resultKey)
                ToastView.show("Imported from Opaline: \(result)", in: window)
                return
            }
            guard OPOpalineImport.available, !defaults.bool(forKey: offeredKey) else {
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let container = OPOpalineImport.opalineContainer
                DispatchQueue.main.async {
                    guard let container else {
                        return
                    }
                    defaults.set(true, forKey: offeredKey)
                    offer(container, from: top, firstLaunch: true)
                }
            }
        }
    }

    /// From Settings.
    static func start(from controller: UIViewController) {
        guard let container = OPOpalineImport.opalineContainer else {
            return
        }
        offer(container, from: controller, firstLaunch: false)
    }

    private static func offer(_ container: URL, from controller: UIViewController, firstLaunch: Bool) {
        let size = ByteCountFormatter.string(
            fromByteCount: Int64(OPOpalineImport.sizeOfFiles(in: container)), countStyle: .file
        )
        let intro = firstLaunch ? "Opaline is installed on this iPhone. " : ""
        let alert = UIAlertController(
            title: "Import from Opaline?",
            message: intro
                + "Girasol can bring over its settings, sign-ins, music and downloads (\(size)). "
                + "What Girasol has of its own is replaced; Opaline stays as it is.\n\n"
                + "Girasol closes when it is done. Open it again to continue.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: firstLaunch ? "Not now" : "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Import", style: .default) { _ in
            run(container, from: controller)
        })
        controller.present(alert, animated: true)
    }

    private static func run(_ container: URL, from controller: UIViewController) {
        // Nothing may write its own state over what comes in.
        MusicPlayer.shared.stop()
        let progress = UIAlertController(title: "Importing from Opaline…", message: nil, preferredStyle: .alert)
        controller.present(progress, animated: true)
        OPOpalineImport.runImport(from: container) { summary, failure in
            guard let summary else {
                progress.dismiss(animated: true) {
                    let alert = UIAlertController(
                        title: "Import failed",
                        message: failure ?? "Opaline's data could not be read.",
                        preferredStyle: .alert
                    )
                    alert.addAction(UIAlertAction(title: "OK", style: .default))
                    controller.present(alert, animated: true)
                }
                return
            }
            UserDefaults.standard.set(summary, forKey: resultKey)
            UserDefaults.standard.set(true, forKey: offeredKey)
            UserDefaults.standard.synchronize()
            AppLog.log("App", "opaline import done, closing")
            exit(0)
        }
    }

    private static func topViewController(of window: UIWindow) -> UIViewController? {
        var top = window.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}
