import UIKit

/// Music home: Speed dial (the albums and playlists played most, lately),
/// Listen again (see `MusicListenAgain`), then YouTube Music's own home
/// shelves — personal with the optional web sign-in, the public ones
/// without it.
final class MusicHomeViewController: MusicListViewController {
    private static let rowsPerShelf = 30
    private var shelves: [(title: String, entries: [MusicEntry])] = []
    private var history: [Video] = []
    private var remote: [(title: String, entries: [MusicEntry])] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Home"
        installRootBarItems()
        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(load), for: .valueChanged)
        tableView.refreshControl = refresh
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(load),
            name: .OPMusicWebAccountDidChange,
            object: nil
        )
        spinner.startAnimating()
        load()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Speed dial is local and cheap: refresh it whenever Home comes back.
        if !shelves.isEmpty || !spinner.isAnimating {
            rebuild()
        }
    }

    @objc
    private func load() {
        let group = DispatchGroup()
        group.enter()
        MusicListenAgain.load { [weak self] songs in
            self?.history = songs
            group.leave()
        }
        group.enter()
        YTMusicPublic.home { [weak self] shelves in
            self?.remote = shelves
            group.leave()
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else {
                return
            }
            self.spinner.stopAnimating()
            self.tableView.refreshControl?.endRefreshing()
            self.rebuild()
        }
    }

    private func rebuild() {
        var shelves: [(title: String, entries: [MusicEntry])] = []
        let dial = MusicPlayLog.shared.speedDial()
        if !dial.isEmpty {
            shelves.append(("Speed dial", dial.map { .playlist($0) }))
        }
        if !history.isEmpty {
            shelves.append(("Listen again", history.prefix(Self.rowsPerShelf).map { .song($0) }))
        }
        shelves += remote
        self.shelves = shelves
        showMessage(
            shelves.isEmpty
                ? "Albums and playlists you play show up here." : nil
        )
        tableView.reloadData()
    }

    private func entries(in section: Int) -> [MusicEntry] {
        Array(shelves[section].entries.prefix(Self.rowsPerShelf))
    }

    private func songs(in section: Int) -> [Video] {
        entries(in: section).compactMap { entry in
            if case .song(let video) = entry {
                return video
            }
            return nil
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        shelves.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        entries(in: section).count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        shelves[section].title
    }

    override func tableView(
        _ tableView: UITableView,
        willDisplay cell: UITableViewCell,
        forRowAt indexPath: IndexPath
    ) {
        guard let cell = cell as? MusicItemCell else {
            return
        }
        switch entries(in: indexPath.section)[indexPath.row] {
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
            cell.configure(
                title: playlist.title,
                subtitle: playlist.description,
                artworkURL: playlist.thumbnailURL
            )
        }
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard case .song(let video) = entries(in: indexPath.section)[indexPath.row] else {
            return nil
        }
        return downloadSwipe(for: video)
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch entries(in: indexPath.section)[indexPath.row] {
        case .song(let video):
            // The shelf's songs become the queue, starting at the tapped one.
            let tracks = songs(in: indexPath.section)
            MusicPlayer.shared.play(
                tracks: tracks,
                startAt: tracks.firstIndex { $0.id == video.id } ?? 0
            )
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
