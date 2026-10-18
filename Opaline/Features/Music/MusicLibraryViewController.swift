import UIKit

/// The YouTube Music library: liked albums, then Liked songs and the saved
/// playlists, then followed artists; downloads last.
final class MusicLibraryViewController: MusicListViewController {
    private enum Section: Int, CaseIterable {
        case albums, playlists, artists, downloads

        var title: String {
            switch self {
            case .downloads:
                return "Downloads"
            case .artists:
                return "Artists"
            case .albums:
                return "Albums"
            case .playlists:
                return "Playlists"
            }
        }
    }

    /// YouTube Music's own "Liked songs" list, opened like any playlist.
    private static let likedSongs = Playlist(
        id: "LM",
        title: "Liked songs",
        description: "Auto playlist",
        thumbnailURL: nil,
        itemCount: nil
    )

    /// The web account's identity goes to the log once per launch.
    private static var loggedIdentity = false
    private var albums: [Playlist] = []
    private var artists: [MusicArtistRef] = []
    private var playlists: [Playlist] = [newPlaylist, likedSongs]

    /// First row of Playlists: makes a new one.
    private static let newPlaylist = Playlist(
        id: "opaline.new",
        title: "New playlist",
        description: "Create a playlist",
        thumbnailURL: nil,
        itemCount: nil
    )

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playlistsChanged(_:)),
            name: MusicPlaylistEditor.didChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerDidChange),
            name: MusicPlaylistPrivacy.didChangeNotification,
            object: nil
        )
        title = "Library"
        installRootBarItems()
        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(load), for: .valueChanged)
        tableView.refreshControl = refresh
        load()
    }

    @objc
    private func load() {
        let group = DispatchGroup()
        var albums: [Playlist] = []
        var playlists: [Playlist] = []
        group.enter()
        ServiceContainer.music.fetchMusicCollection(browseId: "FEmusic_liked_albums") {
            albums = (try? $0.get()) ?? []
            group.leave()
        }
        group.enter()
        ServiceContainer.music.fetchMusicCollection(browseId: "FEmusic_liked_playlists") {
            playlists = (try? $0.get()) ?? []
            group.leave()
        }
        // With the web account, its own list: the playlists it creates are
        // there at once (and only there, if it is another channel).
        var webPlaylists: [Playlist]?
        group.enter()
        YTMusicPublic.libraryPlaylists {
            webPlaylists = $0
            group.leave()
        }
        if !Self.loggedIdentity {
            Self.loggedIdentity = true
            YTMusicPublic.logWebAccountIdentity()
        }
        // With the web account, YouTube Music's own list of followed
        // artists; else they fill in as followed channels are checked.
        let showArtists: ([MusicArtistRef]) -> Void = { [weak self] artists in
            guard let self else {
                return
            }
            self.artists = artists
            self.tableView.reloadSections(
                IndexSet(integer: Section.artists.rawValue), with: .none
            )
        }
        YTMusicPublic.libraryArtists { artists in
            guard let artists, !artists.isEmpty else {
                MusicFollowedArtists.load(update: showArtists)
                return
            }
            showArtists(artists)
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else {
                return
            }
            self.tableView.refreshControl?.endRefreshing()
            self.albums = albums
            if let web = webPlaylists, !web.isEmpty {
                let tvIds = Set(playlists.map(\.id))
                let webIds = Set(web.map(\.id))
                AppLog.innertube(
                    "library: web account \(web.count) playlists, TV \(playlists.count);"
                        + " only web: \(web.filter { !tvIds.contains($0.id) }.map(\.title)),"
                        + " only TV: \(playlists.filter { !webIds.contains($0.id) }.map(\.title))"
                )
                playlists = web
            }
            // The liked-playlists shelf lists Liked songs too, under its own id.
            self.fetchedPlaylists = playlists.filter { $0.id != "LM" }
            self.reconcile()
            self.tableView.reloadData()
            MusicPlaylistPrivacy.refresh(self.fetchedPlaylists.map(\.id))
        }
    }

    // MARK: - Changes the list has not caught up with

    /// The playlists as YouTube last listed them.
    private var fetchedPlaylists: [Playlist] = []
    private var pendingCreated: [Playlist] = []
    private var pendingDeleted: Set<String> = []
    /// Songs added or removed per playlist, with the count the list showed
    /// at the first change: kept until the list shows another count.
    private var pendingSongs: [String: (base: Int?, delta: Int)] = [:]

    @objc
    private func playlistsChanged(_ note: Notification) {
        switch note.userInfo?["change"] as? MusicPlaylistChange {
        case .created(let playlist):
            pendingCreated.insert(playlist, at: 0)
        case .deleted(let id):
            pendingDeleted.insert(id)
            pendingCreated.removeAll { $0.id == id }
        case .songs(let id, let delta) where delta != 0:
            let base = pendingSongs[id]?.base
                ?? (fetchedPlaylists + pendingCreated).first { $0.id == id }.flatMap { Self.songCount(in: $0.description) }
            pendingSongs[id] = (base, (pendingSongs[id]?.delta ?? 0) + delta)
        default:
            break
        }
        applyPending()
        tableView.reloadData()
        load()
        // YouTube's list lags: once more when it has likely caught up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.load()
        }
    }

    /// Drops what the fetched list now shows by itself.
    private func reconcile() {
        let ids = Set(fetchedPlaylists.map(\.id))
        pendingCreated.removeAll { ids.contains($0.id) }
        pendingDeleted = pendingDeleted.filter { ids.contains($0) }
        pendingSongs = pendingSongs.filter { id, pending in
            let shown = fetchedPlaylists.first { $0.id == id }.flatMap { Self.songCount(in: $0.description) }
            return shown == nil || shown == pending.base
        }
        applyPending()
    }

    private func applyPending() {
        let listed = pendingCreated + fetchedPlaylists.filter { !pendingDeleted.contains($0.id) }
        playlists = [Self.newPlaylist, Self.likedSongs] + listed.map { playlist in
            guard let pending = pendingSongs[playlist.id] else {
                return playlist
            }
            return Playlist(
                id: playlist.id, title: playlist.title,
                description: Self.adjust(playlist.description, by: pending.delta, from: pending.base),
                thumbnailURL: playlist.thumbnailURL, itemCount: playlist.itemCount
            )
        }
    }

    private static let countPattern = try? NSRegularExpression(pattern: "(\\d[\\d,]*)\\s+(track|song)s?", options: [])

    /// "Playlist • 12 tracks" → 12.
    private static func songCount(in text: String) -> Int? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = countPattern?.firstMatch(in: text, range: range),
              let number = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return Int(text[number].replacingOccurrences(of: ",", with: ""))
    }

    /// The count in `text` moved by `delta` (or written in, when there was
    /// none, e.g. a playlist just created).
    private static func adjust(_ text: String, by delta: Int, from base: Int?) -> String {
        let count = max(0, (base ?? 0) + delta)
        let words = "\(count) \(count == 1 ? "track" : "tracks")"
        let range = NSRange(text.startIndex..., in: text)
        guard let match = countPattern?.firstMatch(in: text, range: range), let whole = Range(match.range, in: text) else {
            return text.isEmpty ? words : "\(text) • \(words)"
        }
        return text.replacingCharacters(in: whole, with: words)
    }

    private func collections(in section: Int) -> [Playlist] {
        switch Section(rawValue: section) {
        case .downloads:
            // Works offline: both come from the device.
            return [MusicDownloads.allSongs, MusicDownloads.storage] + MusicDownloads.collections()
        case .albums:
            return albums
        default:
            return playlists
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        Section(rawValue: section) == .artists ? artists.count : collections(in: section).count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        Section(rawValue: section)?.title
    }

    override func tableView(
        _ tableView: UITableView,
        willDisplay cell: UITableViewCell,
        forRowAt indexPath: IndexPath
    ) {
        if Section(rawValue: indexPath.section) == .artists {
            let artist = artists[indexPath.row]
            (cell as? MusicItemCell)?.configure(
                title: artist.name, subtitle: artist.subtitle, artworkURL: artist.thumbnailURL
            )
            return
        }
        let collection = collections(in: indexPath.section)[indexPath.row]
        let privacy = Section(rawValue: indexPath.section) == .playlists
            ? MusicPlaylistPrivacy.known(collection.id) : nil
        // A download the app did not finish says so.
        var progress: String?
        if Section(rawValue: indexPath.section) == .downloads, !collection.id.hasPrefix("opaline.") {
            let count = MusicDownloads.savedCount(ofCollection: collection.id)
            progress = count.saved < count.total ? "\(count.saved) of \(count.total) downloaded" : nil
        }
        (cell as? MusicItemCell)?.configure(
            title: collection.title,
            subtitle: [privacy?.shortTitle, progress, collection.description]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
            artworkURL: collection.thumbnailURL
        )
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard Section(rawValue: indexPath.section) != .artists else {
            return nil
        }
        let collection = collections(in: indexPath.section)[indexPath.row]
        // Playlists only; Liked songs and the New row cannot go.
        guard Section(rawValue: indexPath.section) == .playlists,
              collection.id.hasPrefix("PL")
        else {
            return nil
        }
        let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, view, done in
            guard let self else {
                done(false)
                return
            }
            MusicPlaylistEditor.delete(collection, from: self, anchor: view)
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if Section(rawValue: indexPath.section) == .artists {
            MusicNavigator.openArtist(artists[indexPath.row], from: self)
            return
        }
        let picked = collections(in: indexPath.section)[indexPath.row]
        guard picked.id != MusicDownloads.storageId else {
            navigationController?.pushViewController(MusicStorageViewController(), animated: true)
            return
        }
        guard picked.id != Self.newPlaylist.id else {
            MusicPlaylistEditViewController.present(playlist: nil, tracks: [], from: self) { _ in }
            return
        }
        navigationController?.pushViewController(
            MusicCollectionViewController(
                collection: collections(in: indexPath.section)[indexPath.row]
            ),
            animated: true
        )
    }
}
