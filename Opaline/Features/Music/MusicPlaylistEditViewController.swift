import UIKit

/// One screen for a new playlist and for editing one: title, description and
/// privacy edited in place, the songs reordered by dragging and removed by
/// swiping. Save sends only what changed.
final class MusicPlaylistEditViewController: UITableViewController, UITextFieldDelegate {
    private enum Section: Int, CaseIterable {
        case details, privacy, songs, delete
    }

    /// Nil for a new playlist.
    private let existing: Playlist?
    /// The songs as opened, with each row's entry id; `rows` is what is left
    /// of them, in the order now shown. Rows, not video ids: a song in the
    /// playlist twice is two rows that move and go on their own.
    private let allTracks: [Video]
    private let entryIds: [String?]
    private var rows: [Int]
    private var tracks: [Video] {
        rows.map { allTracks[$0] }
    }
    private let titleField = UITextField()
    private let descriptionField = UITextField()
    /// Nil: unchanged (YouTube does not tell an existing playlist's privacy).
    private var privacy: PlaylistPrivacy?
    private let onSaved: (Playlist?) -> Void
    private var isSaving = false

    /// - Parameter onSaved: the playlist as saved, or nil once deleted.
    init(playlist: Playlist?, tracks: [Video], entryIds: [String?] = [], onSaved: @escaping (Playlist?) -> Void) {
        existing = playlist
        allTracks = tracks
        self.entryIds = tracks.indices.map { entryIds.indices.contains($0) ? entryIds[$0] : nil }
        rows = Array(tracks.indices)
        privacy = playlist == nil ? .privateList : nil
        self.onSaved = onSaved
        super.init(style: .insetGrouped)
        title = playlist == nil ? "New playlist" : "Edit playlist"
        titleField.text = playlist?.title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let theme = ThemeManager.shared
        tableView.backgroundColor = theme.background
        tableView.isEditing = true
        tableView.allowsSelectionDuringEditing = true
        tableView.register(MusicItemCell.self, forCellReuseIdentifier: MusicItemCell.reuseId)
        for (field, placeholder) in [(titleField, "Title"), (descriptionField, "Description")] {
            field.placeholder = placeholder
            field.textColor = theme.primaryText
            field.clearButtonMode = .whileEditing
            field.delegate = self
            field.returnKeyType = .done
        }
        titleField.font = .systemFont(ofSize: 17, weight: .semibold)
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(cancel)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: existing == nil ? "Create" : "Save", style: .done, target: self, action: #selector(save)
        )
        if existing == nil {
            titleField.becomeFirstResponder()
        }
        // Moves and removals need entry ids; load them from the public page
        // when the signed-in page did not carry them.
        if let existing, let first = tracks.first,
           MusicPlaylistItems.setVideoId(of: first.id, in: existing.id) == nil {
            MusicPlaylistItems.loadPublic(playlistId: existing.id) {}
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    @objc
    private func cancel() {
        dismiss(animated: true)
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int {
        existing == nil ? Section.allCases.count - 1 : Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) {
        case .details:
            return 2
        case .privacy:
            return PlaylistPrivacy.allCases.count
        case .songs:
            return tracks.count
        default:
            return 1
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .privacy:
            return "Who can see it"
        case .songs:
            return tracks.isEmpty ? nil : "Songs — drag to reorder, swipe to remove"
        default:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        Section(rawValue: section) == .privacy && existing != nil && privacy == nil
            ? "Leave unpicked to keep it as it is." : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let theme = ThemeManager.shared
        switch Section(rawValue: indexPath.section) {
        case .details:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.backgroundColor = theme.surface
            cell.selectionStyle = .none
            let field = indexPath.row == 0 ? titleField : descriptionField
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
                field.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
                field.topAnchor.constraint(equalTo: cell.contentView.topAnchor),
                field.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor),
                field.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
            ])
            return cell
        case .privacy:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            let option = PlaylistPrivacy.allCases[indexPath.row]
            cell.backgroundColor = theme.surface
            cell.textLabel?.text = option.title
            cell.textLabel?.textColor = theme.primaryText
            cell.tintColor = theme.accent
            cell.accessoryType = option == privacy ? .checkmark : .none
            cell.editingAccessoryType = cell.accessoryType
            return cell
        case .songs:
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: MusicItemCell.reuseId, for: indexPath
            ) as? MusicItemCell else {
                return UITableViewCell()
            }
            let track = tracks[indexPath.row]
            cell.configure(title: track.title, subtitle: track.channelName, artworkURL: track.thumbnailURL)
            cell.backgroundColor = theme.surface
            return cell
        default:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.backgroundColor = theme.surface
            cell.textLabel?.text = "Delete playlist"
            cell.textLabel?.textColor = .systemRed
            cell.textLabel?.textAlignment = .center
            return cell
        }
    }

    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        Section(rawValue: indexPath.section) == .songs ? MusicItemCell.height : 48
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Section(rawValue: indexPath.section) {
        case .privacy:
            privacy = PlaylistPrivacy.allCases[indexPath.row]
            tableView.reloadSections(IndexSet(integer: indexPath.section), with: .none)
        case .delete:
            guard let existing else {
                return
            }
            MusicPlaylistEditor.delete(existing, from: self, anchor: tableView.cellForRow(at: indexPath)) {
                [weak self] in
                self?.dismiss(animated: true) {
                    self?.onSaved(nil)
                }
            }
        default:
            break
        }
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        Section(rawValue: indexPath.section) == .songs
    }

    override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        Section(rawValue: indexPath.section) == .songs
    }

    override func tableView(
        _ tableView: UITableView,
        editingStyleForRowAt indexPath: IndexPath
    ) -> UITableViewCell.EditingStyle {
        Section(rawValue: indexPath.section) == .songs ? .delete : .none
    }

    override func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool {
        Section(rawValue: indexPath.section) == .songs
    }

    override func tableView(
        _ tableView: UITableView,
        targetIndexPathForMoveFromRowAt source: IndexPath,
        toProposedIndexPath proposed: IndexPath
    ) -> IndexPath {
        guard proposed.section != source.section else {
            return proposed
        }
        return IndexPath(row: proposed.section < source.section ? 0 : tracks.count - 1, section: source.section)
    }

    override func tableView(_ tableView: UITableView, moveRowAt source: IndexPath, to destination: IndexPath) {
        rows.insert(rows.remove(at: source.row), at: destination.row)
    }

    override func tableView(
        _ tableView: UITableView,
        commit editingStyle: UITableViewCell.EditingStyle,
        forRowAt indexPath: IndexPath
    ) {
        guard editingStyle == .delete else {
            return
        }
        rows.remove(at: indexPath.row)
        tableView.deleteRows(at: [indexPath], with: .automatic)
    }

    // MARK: - Saving

    @objc
    private func save() {
        view.endEditing(true)
        let title = (titleField.text ?? "").trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else {
            ToastView.show("A playlist needs a title", in: view, isError: true)
            return
        }
        guard !isSaving else {
            return
        }
        isSaving = true
        navigationItem.rightBarButtonItem?.isEnabled = false
        if let existing {
            update(existing, title: title)
        } else {
            create(title: title)
        }
    }

    private func create(title: String) {
        let description = descriptionField.text ?? ""
        ServiceContainer.music.createPlaylist(
            title: title,
            privacy: privacy ?? .privateList,
            videoIds: tracks.map(\.id)
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                guard case .success(let id) = result else {
                    self.failed(MusicPlaylistEditor.createFailureMessage)
                    return
                }
                let created = Playlist(
                    id: id, title: title, description: description,
                    thumbnailURL: self.tracks.first?.thumbnailURL, itemCount: self.tracks.count
                )
                let finish = {
                    MusicPlaylistEditor.post(.created(created))
                    self.dismiss(animated: true) {
                        self.onSaved(created)
                    }
                }
                guard !description.isEmpty else {
                    finish()
                    return
                }
                MusicPlaylistAPI.edit(
                    playlistId: id,
                    actions: [["action": "ACTION_SET_PLAYLIST_DESCRIPTION", "playlistDescription": description]]
                ) { _ in
                    DispatchQueue.main.async(execute: finish)
                }
            }
        }
    }

    private func update(_ playlist: Playlist, title: String) {
        var actions: [[String: Any]] = []
        if title != playlist.title {
            actions.append(["action": "ACTION_SET_PLAYLIST_NAME", "playlistName": title])
        }
        if let description = descriptionField.text, !description.isEmpty {
            actions.append(["action": "ACTION_SET_PLAYLIST_DESCRIPTION", "playlistDescription": description])
        }
        if let privacy {
            actions.append(InnertubeClient.privacyAction(privacy))
        }
        // Removals first, row by row (entry ids; by video id only for a song
        // that is in the playlist once), then the moves among what is left.
        let remembered = MusicPlaylistItems.entryIds(for: allTracks, in: playlist.id)
        let ids = allTracks.indices.map { entryIds[$0] ?? remembered[$0] }
        let counts = Dictionary(allTracks.map { ($0.id, 1) }, uniquingKeysWith: +)
        let kept = Set(rows)
        for index in allTracks.indices where !kept.contains(index) {
            let track = allTracks[index]
            guard let action = MusicPlaylistItems.removeAction(
                videoId: track.id, entryId: ids[index], unique: counts[track.id] == 1
            ) else {
                failed("\"\(track.title)\" is in the playlist twice and YouTube did not say which copy is which")
                return
            }
            actions.append(action)
        }
        let remaining = allTracks.indices.filter { kept.contains($0) }
        if remaining != rows {
            guard let moves = MusicPlaylistItems.moveActions(
                fromEntries: remaining.map { ids[$0] }, to: rows.map { ids[$0] }
            ) else {
                AppLog.player("playlist edit: no entry ids for \(playlist.id), cannot reorder")
                failed("YouTube did not give this playlist's order handles; it cannot be reordered from here")
                return
            }
            actions += moves
        }
        guard !actions.isEmpty else {
            dismiss(animated: true)
            return
        }
        AppLog.player("playlist edit \(playlist.id): \(actions.count) actions")
        MusicPlaylistAPI.edit(playlistId: playlist.id, actions: actions) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                guard case .success = result else {
                    self.failed("Could not save the changes")
                    return
                }
                let saved = Playlist(
                    id: playlist.id, title: title,
                    description: self.descriptionField.text?.isEmpty == false
                        ? self.descriptionField.text ?? "" : playlist.description,
                    thumbnailURL: playlist.thumbnailURL, itemCount: self.tracks.count
                )
                let removed = self.allTracks.count - self.rows.count
                MusicPlaylistEditor.post(.songs(playlist.id, -removed))
                self.dismiss(animated: true) {
                    self.onSaved(saved)
                }
            }
        }
    }

    private func failed(_ message: String) {
        isSaving = false
        navigationItem.rightBarButtonItem?.isEnabled = true
        ToastView.show(message, in: view, isError: true)
    }

    /// Presents the editor in its own navigation bar.
    static func present(
        playlist: Playlist?,
        tracks: [Video],
        entryIds: [String?] = [],
        from presenter: UIViewController,
        onSaved: @escaping (Playlist?) -> Void
    ) {
        let editor = MusicPlaylistEditViewController(
            playlist: playlist, tracks: tracks, entryIds: entryIds, onSaved: onSaved
        )
        presenter.present(RotatingNavigationController(rootViewController: editor), animated: true)
    }
}
