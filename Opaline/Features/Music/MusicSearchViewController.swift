import UIKit

/// Search YouTube Music: songs, albums or artists.
final class MusicSearchViewController: MusicListViewController, UISearchBarDelegate {
    private let searchBar = UISearchBar()
    private let filter = UISegmentedControl(items: YTMusicPublic.searchFilters.map(\.title))
    private var results: [MusicEntry] = []
    private var lastQuery = ""
    /// Drops answers to queries that were already replaced.
    private var generation = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Search"
        installRootBarItems()
        let theme = ThemeManager.shared
        searchBar.placeholder = "Songs, albums, artists"
        searchBar.delegate = self
        searchBar.searchBarStyle = .minimal
        searchBar.tintColor = theme.accent
        searchBar.searchTextField.textColor = theme.primaryText
        filter.selectedSegmentIndex = 0
        filter.selectedSegmentTintColor = theme.accent
        filter.setTitleTextAttributes([.foregroundColor: theme.primaryText], for: .normal)
        filter.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
        filter.addTarget(self, action: #selector(filterChanged), for: .valueChanged)
        let stack = UIStackView(arrangedSubviews: [searchBar, filter])
        stack.axis = .vertical
        stack.spacing = 8
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 4, left: 8, bottom: 8, right: 8)
        stack.frame.size = stack.systemLayoutSizeFitting(
            CGSize(width: UIScreen.main.bounds.width, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        tableView.tableHeaderView = stack
        // Drag the list, or tap anywhere off the field, to put the keyboard
        // away — the list bounces even when empty, so there is always
        // something to drag.
        tableView.keyboardDismissMode = .onDrag
        tableView.alwaysBounceVertical = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
    }

    @objc
    private func dismissKeyboard() {
        searchBar.resignFirstResponder()
    }

    func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
        searchBar.setShowsCancelButton(true, animated: true)
    }

    func searchBarTextDidEndEditing(_ searchBar: UISearchBar) {
        searchBar.setShowsCancelButton(false, animated: true)
    }

    func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }

    /// As-you-type: waits for a short pause so every keystroke is not a
    /// request.
    private var typingTimer: Timer?

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        typingTimer?.invalidate()
        guard OPMusicSettings.searchAsYouType else {
            return
        }
        typingTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            self?.run()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if lastQuery.isEmpty {
            searchBar.becomeFirstResponder()
        }
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
        run()
    }

    @objc
    private func filterChanged() {
        Feedback.select()
        run()
    }

    private func run() {
        let query = (searchBar.text ?? "").trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            return
        }
        lastQuery = query
        generation += 1
        let mine = generation
        results = []
        tableView.reloadData()
        showMessage(nil)
        spinner.startAnimating()
        let params = YTMusicPublic.searchFilters[filter.selectedSegmentIndex].params
        YTMusicPublic.search(query, filter: params) { [weak self] entries in
            guard let self, mine == self.generation else {
                return
            }
            self.spinner.stopAnimating()
            self.results = entries
            self.showMessage(entries.isEmpty ? "No results for \"\(query)\"." : nil)
            self.tableView.reloadData()
        }
    }

    private var songs: [Video] {
        results.compactMap { entry in
            if case .song(let video) = entry {
                return video
            }
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        results.count
    }

    override func tableView(
        _ tableView: UITableView,
        willDisplay cell: UITableViewCell,
        forRowAt indexPath: IndexPath
    ) {
        guard let cell = cell as? MusicItemCell else {
            return
        }
        switch results[indexPath.row] {
        case .song(let video):
            cell.configure(
                title: video.title,
                subtitle: downloadMark(for: video.id) + video.channelName,
                artworkURL: video.thumbnailURL,
                isCurrent: MusicPlayer.shared.isCurrent(video.id)
            )
            cell.onMore = { [weak self] anchor in
                guard let self else {
                    return
                }
                MusicTrackMenu.show(for: video, from: self, anchor: anchor)
            }
        case .album(let album):
            cell.configure(title: album.title, subtitle: album.subtitle, artworkURL: album.thumbnailURL)
        case .artist(let artist):
            cell.configure(title: artist.name, subtitle: artist.subtitle, artworkURL: artist.thumbnailURL)
        case .playlist(let playlist):
            cell.configure(title: playlist.title, subtitle: playlist.description, artworkURL: playlist.thumbnailURL)
        }
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard case .song(let video) = results[indexPath.row] else {
            return nil
        }
        return downloadSwipe(for: video)
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch results[indexPath.row] {
        case .song(let video):
            // One song, then radio from it.
            MusicPlayer.shared.play(tracks: [video], startAt: 0, title: "\(video.title) radio")
        case .album(let album):
            MusicNavigator.openAlbum(album, from: self)
        case .artist(let artist):
            MusicNavigator.openArtist(artist, from: self)
        case .playlist(let playlist):
            navigationController?.pushViewController(
                MusicCollectionViewController(collection: playlist), animated: true
            )
        }
    }
}
