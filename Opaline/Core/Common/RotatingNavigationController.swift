import UIKit

/// The app-wide navigation controller: forwards rotation queries to the top
/// view controller and replaces the system back button on push with the
/// shared `NavChevron` button, so the chevron looks and sits the same on
/// every screen and iOS version.
final class RotatingNavigationController: UINavigationController {
    override var shouldAutorotate: Bool {
        topViewController?.shouldAutorotate ?? super.shouldAutorotate
    }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        topViewController?.supportedInterfaceOrientations
            ?? super.supportedInterfaceOrientations
    }
    override var prefersStatusBarHidden: Bool {
        topViewController?.prefersStatusBarHidden ?? super.prefersStatusBarHidden
    }
    override var childForStatusBarHidden: UIViewController? {
        topViewController
    }
    /// Style stays with the themed bar, not the top screen: with the
    /// bar auto-hidden on scroll the system would fall back to the
    /// screen's default (dark text), which vanishes on dark content.
    override var childForStatusBarStyle: UIViewController? {
        nil
    }
    override var preferredStatusBarStyle: UIStatusBarStyle {
        ThemeManager.shared.statusBarStyle
    }
    override var prefersHomeIndicatorAutoHidden: Bool {
        topViewController?.prefersHomeIndicatorAutoHidden ?? super.prefersHomeIndicatorAutoHidden
    }
    override var childForHomeIndicatorAutoHidden: UIViewController? {
        topViewController
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Replacing the system back button disables the edge-swipe pop
        // gesture; re-enable it (guarded so the root screen never pops).
        interactivePopGestureRecognizer?.delegate = self
        installFullWidthBackSwipe()
        delegate = self
        applyBarTheme()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applyBarTheme),
            name: ThemeManager.didChangeNotification,
            object: nil
        )
    }

    /// One bar configuration for every navigation bar in the app — bars
    /// with differing appearance setups use different item-layout metrics
    /// (visibly different chevron insets), so the bar styles itself here
    /// instead of per screen.
    @objc
    private func applyBarTheme() {
        let theme = ThemeManager.shared
        navigationBar.tintColor = theme.isDark ? .white : theme.accent
        if #available(iOS 13.0, *) {
            let appearance = UINavigationBarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = theme.surface
            appearance.titleTextAttributes = [.foregroundColor: theme.primaryText]
            navigationBar.standardAppearance = appearance
            navigationBar.scrollEdgeAppearance = appearance
            navigationBar.compactAppearance = appearance
        } else {
            navigationBar.barTintColor = theme.surface
            navigationBar.isTranslucent = false
            navigationBar.barStyle = theme.barStyle
            navigationBar.titleTextAttributes = [.foregroundColor: theme.primaryText]
        }
        setNeedsStatusBarAppearanceUpdate()
    }

    override func pushViewController(
        _ viewController: UIViewController,
        animated: Bool
    ) {
        // `topViewController == nil` means this is the root being installed —
        // it gets no back button. Screens that manage their own left item
        // (e.g. the watch screen) are left alone.
        if topViewController != nil,
           viewController.navigationItem.leftBarButtonItem == nil {
            viewController.navigationItem.hidesBackButton = true
            viewController.navigationItem.leftBarButtonItem = NavChevron.barButton(
                kind: .back,
                target: self,
                action: #selector(popTapped)
            )
        }
        AppLog.nav(
            "push \(type(of: viewController)) onto \(navName) animated=\(animated)"
                + " busy=\(transitionCoordinator != nil)"
        )
        super.pushViewController(viewController, animated: animated)
    }

    override func popViewController(animated: Bool) -> UIViewController? {
        AppLog.nav(
            "pop \(navName) animated=\(animated) busy=\(transitionCoordinator != nil)"
        )
        return super.popViewController(animated: animated)
    }

    /// Which navigation controller a log line is about: named after its root.
    var navName: String {
        let root = viewControllers.first.map { "\(type(of: $0))" } ?? "empty"
        return "nav(\(root), \(viewControllers.count))"
    }

    @objc
    private func popTapped() {
        popViewController(animated: true)
    }
}

/// A screen that can be swiped back from anywhere on it, not only from the
/// screen edge (music lists: the edge strip lost to vertical scrolling).
protocol FullWidthBackSwipe: UIViewController {}

extension RotatingNavigationController: UIGestureRecognizerDelegate {
    private static var fullWidthPanKey = 0

    /// A pan over the whole screen that drives the system's own interactive
    /// pop (same targets as the edge recognizer), so it looks and cancels
    /// exactly like the edge swipe.
    private func installFullWidthBackSwipe() {
        guard let edge = interactivePopGestureRecognizer, let targets = edge.value(forKey: "targets") else {
            return
        }
        let pan = UIPanGestureRecognizer()
        pan.setValue(targets, forKey: "targets")
        pan.delegate = self
        view.addGestureRecognizer(pan)
        objc_setAssociatedObject(self, &Self.fullWidthPanKey, pan, .OBJC_ASSOCIATION_ASSIGN)
    }

    private var fullWidthPan: UIGestureRecognizer? {
        objc_getAssociatedObject(self, &Self.fullWidthPanKey) as? UIGestureRecognizer
    }

    /// Clearly sideways and to the right, and not inside something that
    /// scrolls sideways and can still go back.
    private func fullWidthPanShouldBegin(_ pan: UIPanGestureRecognizer) -> Bool {
        guard topViewController is FullWidthBackSwipe else {
            return false
        }
        let velocity = pan.velocity(in: view)
        guard velocity.x > 0, abs(velocity.x) > abs(velocity.y) * 1.5 else {
            return false
        }
        var hit = view.hitTest(pan.location(in: view), with: nil)
        while let current = hit {
            if let scroll = current as? UIScrollView,
               scroll.contentSize.width > scroll.bounds.width + 1,
               scroll.contentOffset.x > -scroll.adjustedContentInset.left {
                return false
            }
            hit = current.superview
        }
        return true
    }

    /// On a full-width screen, the lists' own pans wait for the sideways
    /// check — else a slightly diagonal swipe back became a scroll.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === fullWidthPan
            && topViewController is FullWidthBackSwipe
            && otherGestureRecognizer.view is UIScrollView
    }

    /// The system delegate this replaces also refuses the swipe while a push
    /// or pop is still animating. A pop started mid-transition (back out of a
    /// playlist right as it slides in) leaves the stack half-transitioned:
    /// the next push never finishes and every touch is swallowed from then
    /// on — the whole UI looks frozen.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === fullWidthPan, let pan = gestureRecognizer as? UIPanGestureRecognizer {
            return viewControllers.count > 1 && transitionCoordinator == nil && fullWidthPanShouldBegin(pan)
        }
        let begin = viewControllers.count > 1 && transitionCoordinator == nil
        AppLog.nav("swipe-back on \(navName): \(begin ? "begins" : "refused")")
        return begin
    }
}

// MARK: - Chevron realignment after transitions

// The chevron aligns itself to the screen edge in layoutSubviews, but a
// layout pass that runs mid-push measures the slot's in-flight position and
// bakes in a wrong shift. Re-align once the transition settles (covering a
// cancelled interactive pop, where `didShow` never fires for the target).
extension RotatingNavigationController: UINavigationControllerDelegate {
    private static func realignChevron(of viewController: UIViewController?) {
        let item = viewController?.navigationItem.leftBarButtonItem
        guard let chevron = item?.customView as? NavChevronButton else {
            return
        }
        chevron.realign()
        // The bar can move the item's wrapper once more within the same
        // layout pass (invisible to the view's own overrides); one more
        // pass on the next tick catches it.
        DispatchQueue.main.async { [weak chevron] in
            chevron?.realign()
        }
    }

    func navigationController(
        _ navigationController: UINavigationController,
        willShow viewController: UIViewController,
        animated: Bool
    ) {
        AppLog.nav("willShow \(type(of: viewController)) in \(navName)")
        Self.realignChevron(of: viewController)
        guard let coordinator = navigationController.transitionCoordinator else {
            return
        }
        // Inside the animation block, so if the slot moved after the first
        // measurement the chevron glides into place with the push instead
        // of visibly jumping after it.
        coordinator.animate(
            alongsideTransition: { _ in
                Self.realignChevron(of: viewController)
            },
            completion: { context in
                AppLog.nav(
                    "transition to \(type(of: viewController))"
                        + (context.isCancelled ? " cancelled" : " finished")
                )
                let shown = context.isCancelled
                    ? navigationController.topViewController
                    : viewController
                Self.realignChevron(of: shown)
            }
        )
    }

    func navigationController(
        _ navigationController: UINavigationController,
        didShow viewController: UIViewController,
        animated: Bool
    ) {
        AppLog.nav("didShow \(type(of: viewController)) in \(navName)")
        Self.realignChevron(of: viewController)
    }
}
