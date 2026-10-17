import UIKit

/// Shared shell of the music screens: a themed plain table of `MusicItemCell`
/// rows that follows the player, so the playing track stays highlighted.
class MusicListViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, FullWidthBackSwipe {
    let tableView = UITableView(frame: .zero, style: .plain)
    let spinner = UIActivityIndicatorView(style: .medium)
    let messageLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(MusicItemCell.self, forCellReuseIdentifier: MusicItemCell.reuseId)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = MusicItemCell.height
        tableView.tableFooterView = UIView()
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        messageLabel.numberOfLines = 0
        messageLabel.textAlignment = .center
        messageLabel.font = .systemFont(ofSize: 15)
        messageLabel.isHidden = true
        for sub in [spinner, messageLabel] as [UIView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            messageLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            messageLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32)
        ])
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerDidChange),
            name: MusicPlayer.didChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerDidChange),
            name: DownloadStore.didChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerDidChange),
            name: MusicNativeNames.didLearnNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applyTheme),
            name: ThemeManager.didChangeNotification,
            object: nil
        )
        applyTheme()
    }

    /// Root screens of a music tab carry the mode switch and settings.
    func installRootBarItems() {
        navigationItem.leftBarButtonItem = ModeSwitch.barButton()
        let settings = UIBarButtonItem(
            image: UIImage(systemName: "gearshape"),
            style: .plain,
            target: self,
            action: #selector(openMusicSettings)
        )
        navigationItem.rightBarButtonItem = settings
    }

    /// Appended to a track's subtitle: where its download stands.
    func downloadMark(for videoId: String) -> String {
        switch MusicDownloads.state(of: videoId) {
        case .downloaded:
            return "↓ "
        case .queued:
            return "… "
        case .none:
            return ""
        }
    }

    /// Swipe left on any song: add it to the queue, and save it or delete
    /// the saved copy.
    func downloadSwipe(for track: Video) -> UISwipeActionsConfiguration? {
        let queue = UIContextualAction(style: .normal, title: "Queue") { [weak self] _, _, done in
            Feedback.tap()
            MusicPlayer.shared.addToQueue(track)
            if let view = self?.view {
                ToastView.show("Added to queue", in: view)
            }
            done(true)
        }
        queue.image = UIImage(systemName: "text.badge.plus")
        queue.backgroundColor = .systemBlue
        let download: UIContextualAction
        if MusicDownloads.state(of: track.id) == .none {
            download = UIContextualAction(style: .normal, title: "Download") { _, _, done in
                Feedback.tap()
                MusicDownloads.download([track])
                done(true)
            }
            download.image = UIImage(systemName: "arrow.down.circle")
            download.backgroundColor = ThemeManager.shared.accent
        } else {
            download = UIContextualAction(style: .destructive, title: "Remove download") { _, _, done in
                MusicDownloads.remove([track])
                done(true)
            }
            download.image = UIImage(systemName: "trash")
        }
        return UISwipeActionsConfiguration(actions: [queue, download])
    }

    /// Music settings, with the app's own settings one row away.
    @objc
    func openMusicSettings() {
        let theme = ThemeManager.shared
        let settings = OPMusicSettingsViewController()
        settings.backgroundColor = theme.background
        settings.cellColor = theme.surface
        settings.textColor = theme.primaryText
        settings.secondaryTextColor = theme.secondaryText
        settings.accentColor = theme.accent
        let nav = RotatingNavigationController(rootViewController: settings)
        settings.onAppSettings = { [weak nav] in
            nav?.pushViewController(SettingsViewController(), animated: true)
        }
        present(nav, animated: true)
    }

    func showMessage(_ text: String?) {
        messageLabel.text = text
        messageLabel.isHidden = text == nil
    }

    @objc
    func applyTheme() {
        let theme = ThemeManager.shared
        view.backgroundColor = theme.background
        tableView.backgroundColor = theme.background
        tableView.separatorColor = theme.separator
        messageLabel.textColor = theme.secondaryText
        spinner.color = theme.secondaryText
        tableView.reloadData()
    }

    @objc
    func playerDidChange() {
        for cell in tableView.visibleCells {
            guard let path = tableView.indexPath(for: cell) else {
                continue
            }
            tableView(tableView, willDisplay: cell, forRowAt: path)
        }
    }

    // MARK: - Table (subclasses fill these in)

    func numberOfSections(in tableView: UITableView) -> Int {
        1
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        0
    }

    func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        tableView.dequeueReusableCell(withIdentifier: MusicItemCell.reuseId, for: indexPath)
    }

    /// Configures the row; called on display and again on player changes.
    func tableView(
        _ tableView: UITableView,
        willDisplay cell: UITableViewCell,
        forRowAt indexPath: IndexPath
    ) {}

    func tableView(
        _ tableView: UITableView,
        willDisplayHeaderView view: UIView,
        forSection section: Int
    ) {
        guard let header = view as? UITableViewHeaderFooterView else {
            return
        }
        header.textLabel?.textColor = ThemeManager.shared.primaryText
        header.textLabel?.font = .systemFont(ofSize: 20, weight: .bold)
        header.backgroundView = UIView()
        header.backgroundView?.backgroundColor = ThemeManager.shared.background
    }
}
