import Foundation

/// Warms the caches of the tabs not opened yet, once per launch. No
/// background fetch: iOS woke the app for it dozens of times a day (two
/// feeds each time, mobile data too), all for tabs that load in a second
/// anyway.
final class BackgroundRefreshService {
    static let shared = BackgroundRefreshService()

    private let feedService: FeedService
    private let historyService: HistoryService
    private let cache: AppCache

    init(
        feedService: FeedService = ServiceContainer.feed,
        historyService: HistoryService = ServiceContainer.history,
        cache: AppCache = .shared
    ) {
        self.feedService = feedService
        self.historyService = historyService
        self.cache = cache
    }

    /// Fills the caches the *other* tabs read on their first open, so
    /// arriving there doesn't start with a spinner. Runs one request at
    /// a time and only once the home feed has settled — on a slow link
    /// a parallel burst would just delay the screen the user is looking
    /// at (the same reason the subscription dots defer their fetches).
    func warmSecondaryCaches() {
        guard !OAuthClient.shared.isAnonymous else {
            return
        }
        fetchSubscriptions { [weak self] in
            self?.warmHistory()
        }
    }

    private func warmHistory() {
        historyService.fetchHistory { [weak self] result in
            DispatchQueue.main.async {
                guard case .success(let page) = result else {
                    AppLog.cache("warm: history failed")
                    return
                }
                self?.cache.setHistoryFeed(page)
                AppLog.cache("warm: history ok videos=\(page.videos.count)")
            }
        }
    }

    private func fetchSubscriptions(then next: @escaping () -> Void) {
        feedService.fetchSubscriptionFeed { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let page):
                    self?.cache.setSubscriptionsFeed(page)
                    AppLog.cache("subs cached videos=\(page.videos.count)")
                case .failure(let error):
                    AppLog.cache("subs fetch failed \(error)")
                }
                next()
            }
        }
    }
}
