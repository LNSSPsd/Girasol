import UIKit

/// A row of the subscriptions list. Shorts are ordinary rows: a short a
/// subscribed channel posted plays in the normal player.
enum FeedRow {
    case video(Video)
}

extension SubscriptionsViewController {
    func rebuildRows() {
        rows = videos.map(FeedRow.video)
    }
}

// MARK: - Data source

extension SubscriptionsViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        isLoadingInitial
            ? SubscriptionsViewController.skeletonCount
            : rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: SubscriptionVideoCell.reuseId,
            for: indexPath
        ) as? SubscriptionVideoCell else {
            return UITableViewCell()
        }
        if isLoadingInitial {
            cell.configureSkeleton()
            return cell
        }
        guard case let .video(video) = rows[indexPath.row] else {
            return cell
        }
        cell.configure(with: video)
        attachHandlers(to: cell, video: video)
        return cell
    }

    private func attachHandlers(to cell: SubscriptionVideoCell, video: Video) {
        cell.onChannelTap = { [weak self] in
            guard let self,
                  let channelId = video.channelId
            else {
                return
            }
            self.navigationController?.pushViewController(
                self.channelViewControllerFactory(
                    channelId,
                    video.channelName
                ),
                animated: true
            )
        }
        cell.onMenuTap = { [weak self] anchor in
            guard let self else {
                return
            }
            // "Hide" has to actually hide it: the server drops it from the
            // feed, and the row goes with it rather than sitting there
            // until the next refresh (#105, #106).
            VideoActionMenu.present(
                video: video,
                from: self,
                anchor: anchor,
                onRemoved: { [weak self] in
                    self?.videos.removeAll { $0.id == video.id }
                    self?.tableView.reloadData()
                },
                feedbackOutcome: .removed
            )
        }
    }
}

// MARK: - Delegate

extension SubscriptionsViewController: UITableViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === tableView else {
            return
        }
        topBarHider.handleScroll(scrollView)
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard !isLoadingInitial,
              case let .video(video) = rows[indexPath.row]
        else {
            return
        }
        markWatchedLocally(video)
        videoRouter.open(video: video, from: self)
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        guard !isLoadingInitial else {
            return SubscriptionVideoCell.rowHeight(
                forWidth: tableView.bounds.width, title: ""
            )
        }
        switch rows[indexPath.row] {
        case let .video(video):
            return SubscriptionVideoCell.rowHeight(
                forWidth: tableView.bounds.width, title: video.title
            )
        }
    }

    func tableView(
        _ tableView: UITableView,
        willDisplay cell: UITableViewCell,
        forRowAt indexPath: IndexPath
    ) {
        guard !isLoadingInitial,
              !isLoadingMore,
              continuationToken != nil,
              indexPath.row >= rows.count - 4
        else { return }

        isLoadingMore = true
        loadMore()
    }
}
