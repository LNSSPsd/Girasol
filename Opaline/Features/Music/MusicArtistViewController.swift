import UIKit

/// An artist: Play (their songs shuffled, then endless radio), Radio, top
/// songs, albums, singles and EPs.
final class MusicArtistViewController: MusicListViewController {
    private let artist: MusicArtistRef
    private var page: MusicArtistPage?
    private let header = UIView()
    private let photo = ThumbnailImageView(frame: .zero)
    private let nameLabel = UILabel()
    private let playButton = UIButton(type: .system)
    private let radioButton = UIButton(type: .system)

    init(artist: MusicArtistRef) {
        self.artist = artist
        super.init(nibName: nil, bundle: nil)
        title = artist.name
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupHeader()
        spinner.startAnimating()
        YTMusicPublic.artist(artist.browseId) { [weak self] page in
            guard let self else {
                return
            }
            self.spinner.stopAnimating()
            guard let page else {
                self.showMessage("Could not load this artist.")
                return
            }
            self.page = page
            self.nameLabel.text = page.name
            if let url = (page.thumbnailURL ?? self.artist.thumbnailURL).flatMap(URL.init(string:)) {
                self.photo.setImage(url: url)
            }
            self.playButton.isEnabled = page.shuffle != nil
                || page.shelves.contains { $0.entries.contains { if case .song = $0 { return true }; return false } }
            if page.shelves.isEmpty {
                self.showMessage("Nothing to play on this channel.")
            }
            self.radioButton.isEnabled = page.radioPlaylistId != nil
            self.tableView.reloadData()
        }
    }

    private func setupHeader() {
        let theme = ThemeManager.shared
        photo.contentMode = .scaleAspectFill
        photo.clipsToBounds = true
        photo.layer.cornerRadius = 80
        photo.backgroundColor = theme.surface
        if let url = artist.thumbnailURL.flatMap(URL.init(string:)) {
            photo.setImage(url: url)
        }
        nameLabel.text = artist.name
        nameLabel.font = .systemFont(ofSize: 26, weight: .bold)
        nameLabel.textColor = theme.primaryText
        nameLabel.textAlignment = .center
        nameLabel.numberOfLines = 2
        for (button, title, symbol, action) in [
            (playButton, " Play", "shuffle", #selector(playTapped)),
            (radioButton, " Radio", "dot.radiowaves.left.and.right", #selector(radioTapped))
        ] {
            button.setTitle(title, for: .normal)
            button.setImage(UIImage(systemName: symbol), for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
            button.tintColor = theme.accent
            button.backgroundColor = theme.surface
            button.layer.cornerRadius = 10
            button.isEnabled = false
            button.addTarget(self, action: action, for: .touchUpInside)
        }
        let buttons = UIStackView(arrangedSubviews: [playButton, radioButton])
        buttons.spacing = 12
        buttons.distribution = .fillEqually
        let stack = UIStackView(arrangedSubviews: [photo, nameLabel, buttons])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(stack)
        NSLayoutConstraint.activate([
            photo.widthAnchor.constraint(equalToConstant: 160),
            photo.heightAnchor.constraint(equalToConstant: 160),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            playButton.heightAnchor.constraint(equalToConstant: 44),
            stack.topAnchor.constraint(equalTo: header.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -16)
        ])
        let width = UIScreen.main.bounds.width
        header.frame.size = header.systemLayoutSizeFitting(
            CGSize(width: width, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        tableView.tableHeaderView = header
    }

    // MARK: - Playing

    /// The artist's own songs in random order — YouTube Music's artist
    /// shuffle — and, once those run out, radio from the last one played.
    @objc
    private func playTapped() {
        Feedback.tap()
        guard let page else {
            return
        }
        guard let shuffle = page.shuffle else {
            // Not an artist: shuffle whatever songs and videos the page has.
            let songs = page.shelves.indices.flatMap { self.songs(in: $0) }.shuffled()
            guard !songs.isEmpty else {
                return
            }
            MusicPlayer.shared.play(tracks: songs, startAt: 0, title: page.name)
            return
        }
        startQueue(playlistId: shuffle.playlistId, videoId: shuffle.videoId, title: "\(page.name) shuffle")
    }

    @objc
    private func radioTapped() {
        Feedback.tap()
        guard let page, let radio = page.radioPlaylistId else {
            return
        }
        startQueue(playlistId: radio, videoId: nil, title: "\(page.name) radio")
    }

    private func startQueue(playlistId: String, videoId: String?, title: String) {
        YTMusicPublic.watchQueue(playlistId: playlistId, videoId: videoId) { [weak self] queue in
            guard let self else {
                return
            }
            guard let queue, !queue.tracks.isEmpty else {
                ToastView.show("Could not start playback", in: self.view, isError: true)
                return
            }
            MusicPlayer.shared.play(
                tracks: queue.tracks,
                startAt: 0,
                endless: queue.continuation,
                title: title
            )
        }
    }

    // MARK: - Table

    /// Shelves as the page has them: top songs, albums, singles, videos,
    /// playlists — whatever the channel offers.
    private var shelves: [(title: String, entries: [MusicEntry])] {
        page?.shelves ?? []
    }

    private func entry(at indexPath: IndexPath) -> MusicEntry {
        shelves[indexPath.section].entries[indexPath.row]
    }

    private func songs(in section: Int) -> [Video] {
        shelves[section].entries.compactMap { entry in
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
        shelves[section].entries.count
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
        switch entry(at: indexPath) {
        case .song(let song):
            cell.configure(
                title: song.title,
                subtitle: downloadMark(for: song.id) + [song.channelName, song.duration ?? ""]
                    .filter { !$0.isEmpty }.joined(separator: " · "),
                artworkURL: song.thumbnailURL,
                isCurrent: MusicPlayer.shared.isCurrent(song.id)
            )
            cell.onMore = { [weak self] anchor in
                guard let self else {
                    return
                }
                MusicTrackMenu.show(for: song, from: self, anchor: anchor)
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
        guard case .song(let song) = entry(at: indexPath) else {
            return nil
        }
        return downloadSwipe(for: song)
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let page else {
            return
        }
        switch entry(at: indexPath) {
        case .song(let song):
            // The shelf's songs from here, then radio.
            let list = songs(in: indexPath.section)
            MusicPlayer.shared.play(
                tracks: list,
                startAt: list.firstIndex { $0.id == song.id } ?? 0,
                title: page.name
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
