import UIKit

/// A shared Spotify playlist, its tracks found on YouTube Music
/// (`MusicSpotifyMatcher`): playable as it is, and importable as a YouTube
/// Music playlist of the songs that were found. Tracks with no match stay
/// in the list, dimmed, and are left out of playing and importing.
final class MusicSpotifyViewController: MusicListViewController {
    /// Speed dial keeps a played Spotify playlist under this id prefix
    /// (`opaline.` ids are the app's own: never sent to YouTube).
    static let collectionPrefix = "opaline.spotify."

    private let playlistId: String
    private var playlist: OPSpotifyPlaylist?
    private var tracks: [OPSpotifyTrack] = []
    /// Beside `tracks`: nil while searching, `.some(nil)` when none.
    private var matches: [Video??] = []
    private var isMatching = false
    private let header = UIView()
    private let artwork = ThumbnailImageView(frame: .zero)
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let statusLabel = UILabel()
    private let playButton = UIButton(type: .system)
    private let shuffleButton = UIButton(type: .system)
    private let importButton = UIButton(type: .system)

    private var found: [Video] {
        matches.compactMap { $0 ?? nil }
    }

    init(playlistId: String) {
        self.playlistId = playlistId
        super.init(nibName: nil, bundle: nil)
        title = "Spotify playlist"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupHeader()
        spinner.startAnimating()
        OPSpotifyPlaylist.fetchId(playlistId) { [weak self] playlist in
            guard let self else {
                return
            }
            self.spinner.stopAnimating()
            guard let playlist else {
                AppLog.player("spotify playlist \(self.playlistId): could not be read")
                self.showMessage("Could not open this Spotify playlist. It may be private or deleted.")
                return
            }
            AppLog.player(
                "spotify playlist \(self.playlistId) \"\(playlist.name)\": \(playlist.tracks.count) tracks"
                    + " (\(playlist.source))"
            )
            self.show(playlist)
        }
    }

    private func show(_ playlist: OPSpotifyPlaylist) {
        self.playlist = playlist
        tracks = playlist.tracks
        matches = Array(repeating: nil, count: tracks.count)
        title = playlist.name
        titleLabel.text = playlist.name
        subtitleLabel.text = ["Spotify", playlist.owner, "\(tracks.count) songs"]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        if let cover = playlist.coverURL, let url = URL(string: cover) {
            artwork.setImage(url: url)
        }
        tableView.reloadData()
        guard !tracks.isEmpty else {
            showMessage("This playlist is empty.")
            sizeHeader()
            return
        }
        isMatching = true
        updateStatus()
        MusicSpotifyMatcher.matchAll(tracks, each: { [weak self] index, video in
            guard let self, self.matches.indices.contains(index) else {
                return
            }
            self.matches[index] = .some(video)
            self.updateStatus()
            self.tableView.reloadRows(at: [IndexPath(row: index, section: 0)], with: .none)
        }, done: { [weak self] in
            guard let self else {
                return
            }
            self.isMatching = false
            self.updateStatus()
            AppLog.player("spotify playlist \(self.playlistId): \(self.found.count) of \(self.tracks.count) found")
            MusicNativeNames.lookUp(self.found)
        })
    }

    private func updateStatus() {
        let searched = matches.filter { $0 != nil }.count
        var status = isMatching
            ? "Finding songs on YouTube Music… \(searched)/\(tracks.count)"
            : "\(found.count) of \(tracks.count) found on YouTube Music"
        if let playlist, playlist.total > tracks.count {
            status += "\nSpotify only showed \(tracks.count) of its \(playlist.total) songs"
        }
        statusLabel.text = status
        playButton.isEnabled = !found.isEmpty
        shuffleButton.isEnabled = !found.isEmpty
        // The whole list or nothing: an import is not redone.
        importButton.isEnabled = !isMatching && !found.isEmpty
        sizeHeader()
    }

    // MARK: - Header

    private func setupHeader() {
        let theme = ThemeManager.shared
        artwork.contentMode = .scaleAspectFill
        artwork.clipsToBounds = true
        artwork.layer.cornerRadius = 8
        artwork.backgroundColor = theme.surface
        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2
        titleLabel.textColor = theme.primaryText
        for label in [subtitleLabel, statusLabel] {
            label.font = .systemFont(ofSize: 15)
            label.textAlignment = .center
            label.numberOfLines = 0
            label.textColor = theme.secondaryText
        }
        statusLabel.font = .systemFont(ofSize: 13)
        configure(playButton, title: " Play", symbol: "play.fill", action: #selector(playAll))
        configure(shuffleButton, title: " Shuffle", symbol: "shuffle", action: #selector(shuffleAll))
        configure(importButton, title: " Import", symbol: "square.and.arrow.down", action: #selector(importTapped))
        let buttons = UIStackView(arrangedSubviews: [playButton, shuffleButton, importButton])
        buttons.spacing = 12
        buttons.distribution = .fillEqually
        let stack = UIStackView(arrangedSubviews: [artwork, titleLabel, subtitleLabel, statusLabel, buttons])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.setCustomSpacing(16, after: artwork)
        stack.setCustomSpacing(16, after: statusLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(stack)
        NSLayoutConstraint.activate([
            artwork.widthAnchor.constraint(equalToConstant: 200),
            artwork.heightAnchor.constraint(equalToConstant: 200),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            playButton.heightAnchor.constraint(equalToConstant: 44),
            stack.topAnchor.constraint(equalTo: header.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -16)
        ])
        sizeHeader()
    }

    private func configure(_ button: UIButton, title: String, symbol: String, action: Selector) {
        let theme = ThemeManager.shared
        button.setTitle(title, for: .normal)
        button.setImage(UIImage(systemName: symbol), for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        button.tintColor = theme.accent
        button.backgroundColor = theme.surface
        button.layer.cornerRadius = 10
        button.addTarget(self, action: action, for: .touchUpInside)
        button.isEnabled = false
    }

    private func sizeHeader() {
        let width = view.bounds.width > 0 ? view.bounds.width : UIScreen.main.bounds.width
        header.frame.size = header.systemLayoutSizeFitting(
            CGSize(width: width, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        tableView.tableHeaderView = header
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if header.frame.width != view.bounds.width {
            sizeHeader()
        }
    }

    // MARK: - Playing

    @objc
    private func playAll() {
        play(found, from: 0, shuffled: false)
    }

    @objc
    private func shuffleAll() {
        let songs = found
        play(songs, from: Int.random(in: 0..<max(songs.count, 1)), shuffled: true)
    }

    private func play(_ songs: [Video], from index: Int, shuffled: Bool) {
        guard songs.indices.contains(index) else {
            return
        }
        Feedback.tap()
        MusicPlayer.shared.play(
            tracks: songs,
            startAt: index,
            shuffled: shuffled,
            collection: Playlist(
                id: Self.collectionPrefix + playlistId,
                title: playlist?.name ?? "Spotify playlist",
                description: "Spotify",
                thumbnailURL: playlist?.coverURL ?? songs.first?.thumbnailURL,
                itemCount: nil
            )
        )
    }

    // MARK: - Import

    @objc
    private func importTapped() {
        let songs = found
        let missing = tracks.count - songs.count
        let alert = UIAlertController(
            title: "Import to YouTube Music",
            message: "A new playlist with the \(songs.count) songs found"
                + (missing > 0 ? " (\(missing) not on YouTube Music are left out)." : "."),
            preferredStyle: .alert
        )
        alert.addTextField { [weak self] field in
            field.placeholder = "Title"
            field.text = self?.playlist?.name
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Next", style: .default) { [weak self, weak alert] _ in
            let title = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespaces) ?? ""
            guard let self, !title.isEmpty else {
                return
            }
            MusicPlaylistEditor.choosePrivacy(
                title: "Who can see \"\(title)\"?", from: self, anchor: self.importButton
            ) { [weak self] privacy in
                self?.importSongs(songs, title: title, privacy: privacy)
            }
        })
        present(alert, animated: true)
    }

    /// Created with the first 50 songs, the rest added 50 at a time: one
    /// request with every id is more than YouTube is known to take.
    private func importSongs(_ songs: [Video], title: String, privacy: PlaylistPrivacy) {
        let ids = songs.map(\.id)
        importButton.isEnabled = false
        statusLabel.text = "Importing…"
        let chunk = 50
        ServiceContainer.music.createPlaylist(
            title: title, privacy: privacy, videoIds: Array(ids.prefix(chunk))
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                guard case .success(let id) = result else {
                    ToastView.show(MusicPlaylistEditor.createFailureMessage, in: self.view, isError: true)
                    self.updateStatus()
                    return
                }
                self.addRest(Array(ids.dropFirst(chunk)), to: id, added: min(ids.count, chunk), chunk: chunk) { added in
                    self.finishImport(
                        id: id, title: title, privacy: privacy, songs: songs, added: added, of: ids.count
                    )
                }
            }
        }
    }

    private func addRest(
        _ ids: [String],
        to playlistId: String,
        added: Int,
        chunk: Int,
        completion: @escaping (Int) -> Void
    ) {
        guard !ids.isEmpty else {
            completion(added)
            return
        }
        let part = Array(ids.prefix(chunk))
        let actions: [[String: Any]] = part.map {
            ["action": "ACTION_ADD_VIDEO", "addedVideoId": $0, "dedupeOption": "DEDUPE_OPTION_SKIP"]
        }
        MusicPlaylistAPI.edit(playlistId: playlistId, actions: actions) { [weak self] result in
            DispatchQueue.main.async {
                guard case .success = result else {
                    completion(added)
                    return
                }
                self?.statusLabel.text = "Importing… \(added + part.count)/\(added + ids.count)"
                self?.addRest(
                    Array(ids.dropFirst(chunk)), to: playlistId, added: added + part.count,
                    chunk: chunk, completion: completion
                )
            }
        }
    }

    private func finishImport(
        id: String, title: String, privacy: PlaylistPrivacy, songs: [Video], added: Int, of total: Int
    ) {
        AppLog.player("spotify playlist \(playlistId): imported \(added) of \(total) into \(id) (\(privacy.rawValue))")
        updateStatus()
        MusicPlaylistPrivacy.note(id, privacy)
        let created = Playlist(
            id: id, title: title, description: privacy.title, thumbnailURL: nil, itemCount: added
        )
        MusicPlaylistEditor.post(.created(created))
        if added < total {
            ToastView.show("Imported \(added) of \(total) songs: YouTube refused the rest", in: view, isError: true)
        } else {
            ToastView.show("Imported \(added) songs into \(title)", in: view)
        }
        navigationController?.pushViewController(
            MusicCollectionViewController(created: created, tracks: Array(songs.prefix(added))), animated: true
        )
    }

    // MARK: - Table

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        tracks.count
    }

    override func tableView(
        _ tableView: UITableView,
        willDisplay cell: UITableViewCell,
        forRowAt indexPath: IndexPath
    ) {
        guard let cell = cell as? MusicItemCell, tracks.indices.contains(indexPath.row) else {
            return
        }
        let track = tracks[indexPath.row]
        let spotifyArtists = track.artists.joined(separator: ", ")
        switch matches[indexPath.row] {
        case .some(.some(let video)):
            cell.configure(
                title: video.title,
                subtitle: downloadMark(for: video.id) + [video.musicArtist, video.duration ?? ""]
                    .filter { !$0.isEmpty }.joined(separator: " · "),
                artworkURL: video.thumbnailURL,
                isCurrent: MusicPlayer.shared.isCurrent(video.id)
            )
            cell.contentView.alpha = 1
            cell.onMore = { [weak self] anchor in
                guard let self else {
                    return
                }
                MusicTrackMenu.show(for: video, from: self, anchor: anchor)
            }
        case .some(.none):
            cell.configure(title: track.title, subtitle: "Not on YouTube Music · \(spotifyArtists)", artworkURL: nil)
            cell.contentView.alpha = 0.45
            cell.onMore = nil
        case .none:
            cell.configure(title: track.title, subtitle: spotifyArtists, artworkURL: nil)
            cell.contentView.alpha = 0.45
            cell.onMore = nil
        }
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard case .some(.some(let video)) = matches[indexPath.row] else {
            return nil
        }
        return downloadSwipe(for: video)
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard case .some(.some) = matches[indexPath.row] else {
            return
        }
        // The found songs from here on, as an album plays from a track.
        let before = matches[..<indexPath.row].filter { ($0 ?? nil) != nil }.count
        play(found, from: before, shuffled: false)
    }
}
