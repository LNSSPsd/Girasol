import UIKit

/// An album or playlist: artwork, title, Play / Shuffle, and its tracks.
final class MusicCollectionViewController: MusicListViewController {
    private var collection: Playlist
    /// Opened from search or an artist: an album page (`MPREb_…`), loaded
    /// from YouTube Music, which also names its playlist and artist.
    private var albumRef: MusicAlbumRef?
    private var albumArtist: MusicArtistRef?
    private var tracks: [Video] = []
    /// Each row's playlist entry id, beside `tracks`: removals and moves go
    /// by these, so a song in the list twice is two different rows.
    private var entryIds: [String?] = []
    private let header = UIView()
    private let artwork = ThumbnailImageView(frame: .zero)
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    /// Who can see it (`MusicPlaylistPrivacy`), for playlists.
    private let privacyLabel = UILabel()
    private let playButton = UIButton(type: .system)
    private let shuffleButton = UIButton(type: .system)
    private let downloadButton = UIButton(type: .system)
    /// One of the user's own playlists: editable, songs removable. Known
    /// once the add-to-playlist list (own playlists only) names it.
    private var isOwn = false

    private var isAllDownloads: Bool {
        collection.id == MusicDownloads.allSongsId
    }

    /// Album art is square and the same for every track; a playlist's tracks
    /// each show their own.
    private var isAlbum: Bool {
        collection.id.hasPrefix("OLAK")
    }

    init(collection: Playlist) {
        self.collection = collection
        super.init(nibName: nil, bundle: nil)
        title = collection.title
    }

    convenience init(album: MusicAlbumRef) {
        self.init(collection: Playlist(
            id: album.browseId,
            title: album.title,
            description: album.subtitle,
            thumbnailURL: album.thumbnailURL,
            itemCount: nil
        ))
        albumRef = album
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func loadAlbumPage(_ album: MusicAlbumRef) {
        YTMusicPublic.album(album.browseId) { [weak self] page in
            guard let self else {
                return
            }
            self.spinner.stopAnimating()
            guard let page else {
                self.showMessage("Could not load this album.")
                return
            }
            // From here on it is the album's playlist, like a library album:
            // downloads, Speed dial and offline all key on that id.
            self.collection = Playlist(
                id: page.playlistId ?? album.browseId,
                title: page.title.isEmpty ? album.title : page.title,
                description: [page.artist?.name, page.subtitle]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                thumbnailURL: page.thumbnailURL ?? album.thumbnailURL,
                itemCount: page.tracks.count
            )
            self.albumArtist = page.artist
            self.installBarItems()
            self.titleLabel.text = self.collection.title
            self.subtitleLabel.text = self.collection.description
            self.title = self.collection.title
            self.sizeHeader()
            // The songs, not the music videos YouTube Music lists in their place.
            MusicSongVersions.albumTracks(page.tracks, playlistId: self.collection.id, title: self.collection.title) { [weak self] tracks in
                self?.showTracks(tracks)
            }
        }
    }

    /// The artist named under an album's title opens their page — known
    /// from the album page, else found through the album's first song (an
    /// album opened from the library or Speed dial).
    @objc
    private func subtitleTapped() {
        if let artist = albumArtist {
            MusicNavigator.openArtist(artist, from: self)
        } else if isAlbum, let first = tracks.first {
            MusicNavigator.open(.artist, of: first, from: self)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupHeader()
        spinner.startAnimating()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateDownloadButton),
            name: DownloadStore.didChangeNotification,
            object: nil
        )
        installBarItems()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updatePrivacy),
            name: MusicPlaylistPrivacy.didChangeNotification,
            object: nil
        )
        updatePrivacy()
        if MusicPlaylistPrivacy.applies(to: collection.id) {
            MusicPlaylistPrivacy.refresh([collection.id], force: true)
        }
        subtitleLabel.isUserInteractionEnabled = true
        subtitleLabel.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(subtitleTapped))
        )
        if isAllDownloads {
            spinner.stopAnimating()
            showTracks(DownloadStore.downloads().filter { DownloadStore.isDownloaded($0.id) })
        } else if let albumRef {
            loadAlbumPage(albumRef)
        } else {
            loadTracks()
        }
    }

    /// Own playlists are the ones the add-to-playlist list offers.
    private func checkOwnership() {
        guard collection.id.hasPrefix("PL"), let probe = tracks.first else {
            return
        }
        MusicPlaylistAPI.addOptions(videoId: probe.id) { [weak self] result in
            DispatchQueue.main.async {
                guard let self,
                      case .success(let options) = result,
                      options.contains(where: { $0.id == self.collection.id })
                else {
                    return
                }
                self.markOwn()
            }
        }
    }

    private func markOwn() {
        isOwn = true
        installBarItems()
        tableView.reloadData()
    }

    /// Share for anything YouTube has a page of (an unlisted playlist is
    /// only reachable through its link), Edit for your own playlists.
    private func installBarItems() {
        var items: [UIBarButtonItem] = []
        if isOwn {
            items.append(UIBarButtonItem(
                title: "Edit", style: .plain, target: self, action: #selector(showEditMenu)
            ))
        }
        if shareURL != nil {
            items.append(UIBarButtonItem(
                barButtonSystemItem: .action, target: self, action: #selector(share(_:))
            ))
        }
        navigationItem.rightBarButtonItems = items
    }

    /// music.youtube.com's page of it; none for the app's own lists
    /// (downloads, `opaline.` ids).
    private var shareURL: URL? {
        let id = collection.id
        guard !isAllDownloads, !id.hasPrefix("opaline."), !id.isEmpty else {
            return nil
        }
        return id.hasPrefix("MPREb")
            ? URL(string: "https://music.youtube.com/browse/\(id)")
            : URL(string: "https://music.youtube.com/playlist?list=\(id)")
    }

    @objc
    private func share(_ sender: UIBarButtonItem) {
        guard let url = shareURL else {
            return
        }
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        activity.popoverPresentationController?.barButtonItem = sender
        present(activity, animated: true)
    }

    /// The playlist editor: details, privacy, order and removals in place.
    @objc
    private func showEditMenu() {
        let current = Playlist(
            id: collection.id,
            title: titleLabel.text ?? collection.title,
            description: subtitleLabel.text ?? collection.description,
            thumbnailURL: collection.thumbnailURL,
            itemCount: tracks.count
        )
        MusicPlaylistEditViewController.present(
            playlist: current, tracks: tracks, entryIds: (0..<tracks.count).map(entryId(at:)), from: self
        ) {
            [weak self] saved in
            guard let self else {
                return
            }
            guard let saved else {
                // Deleted.
                self.navigationController?.popViewController(animated: true)
                return
            }
            self.titleLabel.text = saved.title
            self.subtitleLabel.text = saved.description
            self.title = saved.title
            self.sizeHeader()
            // Reload, so the order shown is YouTube's.
            self.tracks = []
            self.entryIds = []
            self.tableView.reloadData()
            self.spinner.startAnimating()
            self.loadTracks()
        }
    }

    /// Title and description, sent as YouTube's own playlist edit actions.
    private func editDetails() {
        let alert = UIAlertController(title: "Edit playlist", message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "Title"
            field.text = self.titleLabel.text
        }
        alert.addTextField { field in
            field.placeholder = "Description"
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in
            let title = alert?.textFields?[0].text?.trimmingCharacters(in: .whitespaces) ?? ""
            let description = alert?.textFields?[1].text ?? ""
            self?.saveDetails(title: title, description: description)
        })
        present(alert, animated: true)
    }

    private func saveDetails(title: String, description: String) {
        var actions: [[String: Any]] = []
        if !title.isEmpty, title != titleLabel.text {
            actions.append(["action": "ACTION_SET_PLAYLIST_NAME", "playlistName": title])
        }
        if !description.isEmpty {
            actions.append(["action": "ACTION_SET_PLAYLIST_DESCRIPTION", "playlistDescription": description])
        }
        guard !actions.isEmpty else {
            return
        }
        MusicPlaylistAPI.edit(playlistId: collection.id, actions: actions) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                guard case .success = result else {
                    ToastView.show("Could not save the changes", in: self.view, isError: true)
                    return
                }
                if !title.isEmpty {
                    self.titleLabel.text = title
                    self.title = title
                }
                if !description.isEmpty {
                    self.subtitleLabel.text = description
                }
                self.sizeHeader()
                ToastView.show("Saved", in: self.view)
            }
        }
    }

    /// The row's entry id: from the page, else remembered when the song is
    /// in the list once.
    private func entryId(at index: Int) -> String? {
        let known = entryIds.indices.contains(index) ? entryIds[index] : nil
        return known ?? MusicPlaylistItems.entryIds(for: tracks, in: collection.id)[index]
    }

    /// One of your playlists, as the context of the row at `index`.
    private func ownPlaylistContext(at index: Int) -> MusicTrackMenu.OwnPlaylist? {
        guard isOwn, tracks.indices.contains(index) else {
            return nil
        }
        let track = tracks[index]
        let entry = entryId(at: index)
        return MusicTrackMenu.OwnPlaylist(
            id: collection.id,
            title: titleLabel.text ?? collection.title,
            entryId: entry,
            unique: tracks.filter { $0.id == track.id }.count == 1
        ) { [weak self] in
            self?.removeRow(videoId: track.id, entryId: entry)
        }
    }

    /// The row removed on YouTube: found by its entry id, else (a song in
    /// the list once) by its video id.
    private func removeRow(videoId: String, entryId: String?) {
        let index = entryId.flatMap { id in entryIds.firstIndex { $0 == id } }
            ?? tracks.firstIndex { $0.id == videoId }
        guard let index else {
            return
        }
        tracks.remove(at: index)
        if entryIds.indices.contains(index) {
            entryIds.remove(at: index)
        }
        tableView.deleteRows(at: [IndexPath(row: index, section: 0)], with: .automatic)
    }

    private func showTracks(_ list: [Video], entryIds ids: [String?]? = nil) {
        tracks = list
        MusicNativeNames.lookUp(list)
        entryIds = ids ?? Array(repeating: nil, count: list.count)
        tableView.reloadData()
        playButton.isEnabled = !tracks.isEmpty
        shuffleButton.isEnabled = !tracks.isEmpty
        updateArtwork()
        updateDownloadButton()
        showMessage(tracks.isEmpty ? "Nothing here yet." : nil)
    }

    @objc
    private func updatePrivacy() {
        let privacy = MusicPlaylistPrivacy.known(collection.id)
        privacyLabel.isHidden = privacy == nil
        guard let privacy else {
            sizeHeader()
            return
        }
        let symbol: String
        switch privacy {
        case .publicList:
            symbol = "globe"
        case .unlisted:
            symbol = "link"
        case .privateList:
            symbol = "lock.fill"
        }
        let text = NSMutableAttributedString()
        if let image = UIImage(systemName: symbol)?.withTintColor(
            ThemeManager.shared.secondaryText, renderingMode: .alwaysOriginal
        ) {
            text.append(NSAttributedString(attachment: NSTextAttachment(image: image)))
            text.append(NSAttributedString(string: " "))
        }
        text.append(NSAttributedString(string: privacy.shortTitle))
        privacyLabel.attributedText = text
        sizeHeader()
    }

    @objc
    private func updateDownloadButton() {
        let states = tracks.map { MusicDownloads.state(of: $0.id) }
        let symbol: String
        if !states.isEmpty, states.allSatisfy({ $0 == .downloaded }) {
            // Tapping it then offers to remove the downloads.
            symbol = "checkmark.circle.fill"
            downloadButton.isEnabled = true
        } else if states.contains(.queued) {
            symbol = "arrow.down.circle.fill"
            downloadButton.isEnabled = false
        } else {
            symbol = "arrow.down.circle"
            downloadButton.isEnabled = !tracks.isEmpty
        }
        downloadButton.setImage(UIImage(systemName: symbol), for: .normal)
    }

    @objc
    private func downloadAll() {
        Feedback.tap()
        let all = tracks.allSatisfy { MusicDownloads.state(of: $0.id) == .downloaded }
        guard all else {
            MusicDownloads.download(collection: collection, tracks: tracks)
            updateDownloadButton()
            return
        }
        let sheet = UIAlertController(
            title: "Remove downloads?",
            message: "The \(tracks.count) songs will need a connection again.",
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: "Remove downloads", style: .destructive) { [weak self] _ in
            guard let self else {
                return
            }
            MusicDownloads.remove(collection: self.collection, tracks: self.tracks)
            self.updateDownloadButton()
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        MusicTrackMenu.present(sheet, from: self, anchor: downloadButton)
    }

    // MARK: - Header

    private func setupHeader() {
        let theme = ThemeManager.shared
        artwork.contentMode = .scaleAspectFill
        artwork.clipsToBounds = true
        artwork.layer.cornerRadius = 8
        artwork.backgroundColor = theme.surface
        titleLabel.text = collection.title
        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2
        titleLabel.textColor = theme.primaryText
        subtitleLabel.text = collection.description
        subtitleLabel.font = .systemFont(ofSize: 15)
        subtitleLabel.textAlignment = .center
        // An album's artist line is a link (see `subtitleTapped`).
        subtitleLabel.textColor = isAlbum || albumRef != nil ? theme.accent : theme.secondaryText
        privacyLabel.font = .systemFont(ofSize: 13)
        privacyLabel.textAlignment = .center
        privacyLabel.textColor = theme.secondaryText
        privacyLabel.isHidden = true
        configure(playButton, title: " Play", symbol: "play.fill", action: #selector(playAll))
        configure(
            shuffleButton, title: " Shuffle", symbol: "shuffle", action: #selector(shuffleAll)
        )
        configure(
            downloadButton, title: "", symbol: "arrow.down.circle", action: #selector(downloadAll)
        )
        downloadButton.isHidden = isAllDownloads
        let buttons = UIStackView(arrangedSubviews: [playButton, shuffleButton, downloadButton])
        buttons.spacing = 12
        buttons.distribution = .fillEqually
        let stack = UIStackView(arrangedSubviews: [artwork, titleLabel, subtitleLabel, privacyLabel, buttons])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.setCustomSpacing(16, after: artwork)
        stack.setCustomSpacing(16, after: privacyLabel)
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
        updateArtwork()
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

    private func updateArtwork() {
        let url = collection.thumbnailURL ?? tracks.first?.thumbnailURL
        if let url, let parsed = URL(string: url) {
            artwork.setImage(url: parsed)
        }
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

    // MARK: - Data

    /// With the web account, YouTube Music's own page of the playlist: it
    /// opens empty and private playlists and says whether it is the
    /// account's own. The TV client otherwise (and when that is refused).
    private func loadTracks() {
        guard OPMusicWebAccount.signedIn, !isAlbum, !collection.id.hasPrefix("opaline.") else {
            loadPage(continuation: nil)
            return
        }
        YTMusicPublic.playlist(collection.id) { [weak self] result in
            guard let self else {
                return
            }
            guard let result else {
                self.loadPage(continuation: nil)
                return
            }
            self.spinner.stopAnimating()
            self.showTracks(result.tracks, entryIds: result.entryIds)
            if result.isOwn {
                self.markOwn()
            }
        }
    }

    /// Every page up front: Play and Shuffle need the whole list.
    private func loadPage(continuation: String?) {
        ServiceContainer.playlists.fetchPlaylistVideos(
            playlistId: collection.id,
            continuation: continuation
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                self.spinner.stopAnimating()
                switch result {
                case .success(let page):
                    self.tracks += page.videos
                    self.entryIds += Array(repeating: nil, count: page.videos.count)
                    self.tableView.reloadData()
                    self.playButton.isEnabled = !self.tracks.isEmpty
                    self.shuffleButton.isEnabled = !self.tracks.isEmpty
                    self.updateDownloadButton()
                    if continuation == nil {
                        self.updateArtwork()
                    }
                    if let next = page.continuation {
                        self.loadPage(continuation: next)
                    } else {
                        MusicNativeNames.lookUp(self.tracks)
                        self.checkOwnership()
                        if self.isAlbum {
                            MusicSongVersions.albumTracks(self.tracks, playlistId: self.collection.id, title: self.collection.title) { [weak self] tracks in
                                self?.showTracks(tracks)
                            }
                        }
                    }
                case .failure:
                    // Offline: a downloaded collection still has its list.
                    if self.tracks.isEmpty,
                       let saved = MusicDownloads.savedTracks(of: self.collection.id) {
                        self.showTracks(saved)
                    } else if self.tracks.isEmpty {
                        self.showMessage("Could not load this \(self.isAlbum ? "album" : "playlist").")
                        // Online and still nothing: gone (deleted elsewhere) —
                        // Speed dial stops offering it.
                        if !NetworkType.isOffline {
                            MusicPlayLog.shared.forgetCollection(self.collection.id)
                        }
                    }
                }
            }
        }
    }

    @objc
    private func playAll() {
        play(from: 0, shuffled: false)
    }

    @objc
    private func shuffleAll() {
        play(from: Int.random(in: 0..<max(tracks.count, 1)), shuffled: true)
    }

    private func play(from index: Int, shuffled: Bool) {
        guard tracks.indices.contains(index) else {
            return
        }
        Feedback.tap()
        MusicPlayer.shared.play(
            tracks: tracks,
            startAt: index,
            shuffled: shuffled,
            artworkURL: isAlbum ? collection.thumbnailURL : nil,
            collection: Playlist(
                id: collection.id,
                title: collection.title,
                description: collection.description,
                thumbnailURL: collection.thumbnailURL ?? tracks.first?.thumbnailURL,
                itemCount: nil
            )
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
        let track = tracks[indexPath.row]
        let subtitle = downloadMark(for: track.id) + [track.musicArtist, track.duration ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        guard let cell = cell as? MusicItemCell else {
            return
        }
        cell.configure(
            title: track.title,
            subtitle: subtitle,
            artworkURL: track.thumbnailURL,
            number: isAlbum ? indexPath.row + 1 : nil,
            isCurrent: MusicPlayer.shared.isCurrent(track.id)
        )
        cell.onMore = { [weak self, weak cell] anchor in
            guard let self else {
                return
            }
            // The row as it is now: earlier removals may have moved it.
            let row = cell.flatMap { self.tableView.indexPath(for: $0)?.row } ?? indexPath.row
            let current = self.tracks.indices.contains(row) ? self.tracks[row] : track
            MusicTrackMenu.show(for: current, from: self, anchor: anchor, ownPlaylist: self.ownPlaylistContext(at: row))
        }
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        let track = tracks[indexPath.row]
        var actions = downloadSwipe(for: track)?.actions ?? []
        if isOwn {
            let remove = UIContextualAction(style: .destructive, title: "Remove") { [weak self] _, _, done in
                guard let self, let own = self.ownPlaylistContext(at: indexPath.row) else {
                    done(false)
                    return
                }
                MusicTrackMenu.removeFromPlaylist(track, own, presenter: self)
                done(true)
            }
            // Last, so a full swipe still means Queue.
            actions.append(remove)
        }
        return actions.isEmpty ? nil : UISwipeActionsConfiguration(actions: actions)
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        play(from: indexPath.row, shuffled: false)
    }
}
