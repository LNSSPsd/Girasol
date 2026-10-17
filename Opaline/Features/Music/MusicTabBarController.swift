import UIKit

/// Music mode's window root, the peer of the video mode's tab bar: Home and
/// Library tabs, and the Now Playing bar above the tab bar while a queue is
/// loaded — or, while a video from video mode still plays, its small
/// picture, until a song starts.
final class MusicTabBarController: UITabBarController {
    private let nowPlayingBar = MusicNowPlayingBar()
    private var barHeight: NSLayoutConstraint?
    private var barBottom: NSLayoutConstraint?
    private var videoBar: MiniPlayerBar?
    private var videoBarBottom: NSLayoutConstraint?
    /// Opens the full player once on screen: arriving from the song's bar
    /// in video mode. Static: set before the root exists.
    static var opensPlayer = false

    override var preferredStatusBarStyle: UIStatusBarStyle {
        ThemeManager.shared.statusBarStyle
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        MusicPlayer.shared.restoreSessionIfNeeded()
        MusicLikes.loadIfNeeded()
        viewControllers = [
            tab(MusicHomeViewController(), title: "Home", symbol: "house.fill"),
            tab(MusicSearchViewController(), title: "Search", symbol: "magnifyingglass"),
            tab(MusicLibraryViewController(), title: "Library", symbol: "music.note.list")
        ]
        nowPlayingBar.translatesAutoresizingMaskIntoConstraints = false
        nowPlayingBar.onOpen = { [weak self] in
            self?.openPlayer()
        }
        view.insertSubview(nowPlayingBar, belowSubview: tabBar)
        let bottom = nowPlayingBar.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        NSLayoutConstraint.activate([
            nowPlayingBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            nowPlayingBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            nowPlayingBar.heightAnchor.constraint(equalToConstant: MusicNowPlayingBar.height),
            bottom
        ])
        barBottom = bottom
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerDidChange),
            name: MusicPlayer.didChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applyTheme),
            name: ThemeManager.didChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(videoDidClose),
            name: VideoRouter.didCloseNotification,
            object: nil
        )
        applyTheme()
        playerDidChange()
        showVideoBarIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if Self.opensPlayer {
            Self.opensPlayer = false
            openPlayer()
        }
    }

    private func showVideoBarIfNeeded() {
        let bar = MiniPlayerBar()
        guard VideoRouter.shared.showMiniPlayer(in: bar) else {
            return
        }
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)
        let bottom = bar.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        NSLayoutConstraint.activate([
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            bar.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 1.0 / 3.0),
            bottom
        ])
        videoBar = bar
        videoBarBottom = bottom
    }

    @objc
    private func videoDidClose() {
        videoBar?.attachPlayer(nil)
        videoBar?.removeFromSuperview()
        videoBar = nil
        videoBarBottom = nil
    }

    private func tab(_ root: UIViewController, title: String, symbol: String) -> UIViewController {
        let nav = RotatingNavigationController(rootViewController: root)
        nav.tabBarItem = UITabBarItem(title: title, image: UIImage(systemName: symbol), tag: 0)
        return nav
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Sits on top of the tab bar, wherever the bar ended up.
        barBottom?.constant = -(view.bounds.maxY - tabBar.frame.minY)
        videoBarBottom?.constant = -(view.bounds.maxY - tabBar.frame.minY + 12)
    }

    @objc
    private func playerDidChange() {
        let visible = MusicPlayer.shared.isActive
        nowPlayingBar.isHidden = !visible
        // Keeps the last rows of every list clear of the bar.
        for child in viewControllers ?? [] {
            child.additionalSafeAreaInsets.bottom = visible ? MusicNowPlayingBar.height : 0
        }
    }

    @objc
    private func applyTheme() {
        let theme = ThemeManager.shared
        tabBar.barStyle = theme.barStyle
        tabBar.tintColor = theme.isDark ? .white : theme.accent
        nowPlayingBar.refresh()
        setNeedsStatusBarAppearanceUpdate()
    }

    func openPlayer() {
        let player = MusicPlayerViewController()
        // Over full screen: dragging it down shows the app underneath.
        player.modalPresentationStyle = .overFullScreen
        present(player, animated: true)
    }
}
