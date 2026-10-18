import UIKit

/// The one-tap import from Opaline (`OPOpalineImport`): a button on the
/// sign-in screen (a fresh install: nothing to replace, so no question), and
/// Settings → Import from Opaline (asks first: it replaces what Girasol
/// has). Not an alert at launch: one dismissed by accident would never come
/// back. The import replaces what the app holds in memory, so Girasol
/// closes when it is done and says what came over at the next start.
enum OpalineImportPrompt {
    private static let resultKey = "opalineImport.result"

    /// An unsandboxed build, with Opaline installed.
    static var isAvailable: Bool {
        OPOpalineImport.opalineContainer != nil
    }

    /// At launch, once the first real screen is up: the result of an import
    /// that just closed the app.
    static func launched(in window: UIWindow?) {
        let defaults = UserDefaults.standard
        guard let result = defaults.string(forKey: resultKey) else {
            return
        }
        defaults.removeObject(forKey: resultKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard let window else {
                return
            }
            ToastView.show("Imported from Opaline: \(result)", in: window)
        }
    }

    /// The sign-in screen's button: straight away.
    static func importNow(from controller: UIViewController) {
        guard let container = OPOpalineImport.opalineContainer else {
            return
        }
        run(container, from: controller)
    }

    /// From Settings.
    static func start(from controller: UIViewController) {
        guard let container = OPOpalineImport.opalineContainer else {
            return
        }
        let size = ByteCountFormatter.string(
            fromByteCount: Int64(OPOpalineImport.sizeOfFiles(in: container)), countStyle: .file
        )
        let alert = UIAlertController(
            title: "Import from Opaline?",
            message: "Girasol brings over Opaline's settings, sign-ins, music and downloads (\(size)). "
                + "What Girasol has of its own is replaced; Opaline stays as it is.\n\n"
                + "Girasol closes when it is done. Open it again to continue.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
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
            UserDefaults.standard.synchronize()
            AppLog.log("App", "opaline import done, closing")
            exit(0)
        }
    }
}
