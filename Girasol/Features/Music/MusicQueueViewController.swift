// SPDX-License-Identifier: CC0-1.0
import UIKit

/// Up next: what plays now, the user's queue, then the rest of the album or
/// playlist. Both lists can be reordered (within themselves) and trimmed;
/// the playing track cannot be touched. Tapping an entry plays it.
final class MusicQueueViewController: MusicListViewController {
    private enum Section: Int, CaseIterable {
        case nowPlaying, queue, upcoming
    }

    private let player = MusicPlayer.shared

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Up next"
        tableView.isEditing = true
        tableView.allowsSelectionDuringEditing = true
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(close)
        )
    }

    @objc
    private func close() {
        dismiss(animated: true)
    }

    override func playerDidChange() {
        tableView.reloadData()
    }

    private func tracks(in section: Int) -> [Video] {
        switch Section(rawValue: section) {
        case .nowPlaying:
            return player.current.map { [$0] } ?? []
        case .queue:
            return player.queue
        default:
            return player.upcoming
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        tracks(in: section).count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard !tracks(in: section).isEmpty else {
            return nil
        }
        switch Section(rawValue: section) {
        case .nowPlaying:
            return "Now playing"
        case .queue:
            return "Queue"
        default:
            return player.contextTitle.map { "Next from \($0)" } ?? "Next"
        }
    }

    override func tableView(
        _ tableView: UITableView,
        willDisplay cell: UITableViewCell,
        forRowAt indexPath: IndexPath
    ) {
        let track = tracks(in: indexPath.section)[indexPath.row]
        (cell as? MusicItemCell)?.configure(
            title: track.title,
            subtitle: downloadMark(for: track.id) + track.musicArtist,
            artworkURL: track.thumbnailURL,
            isCurrent: indexPath.section == Section.nowPlaying.rawValue
        )
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Section(rawValue: indexPath.section) {
        case .queue:
            player.jumpInQueue(to: indexPath.row)
        case .upcoming:
            player.jumpInUpcoming(to: indexPath.row)
        default:
            break
        }
    }

    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        indexPath.section != Section.nowPlaying.rawValue
    }

    /// Moves stay inside their own list.
    func tableView(
        _ tableView: UITableView,
        targetIndexPathForMoveFromRowAt source: IndexPath,
        toProposedIndexPath proposed: IndexPath
    ) -> IndexPath {
        guard proposed.section != source.section else {
            return proposed
        }
        let row = proposed.section < source.section
            ? 0 : tableView.numberOfRows(inSection: source.section) - 1
        return IndexPath(row: row, section: source.section)
    }

    func tableView(
        _ tableView: UITableView,
        moveRowAt source: IndexPath,
        to destination: IndexPath
    ) {
        if source.section == Section.queue.rawValue {
            player.moveInQueue(from: source.row, to: destination.row)
        } else {
            player.moveUpcoming(from: source.row, to: destination.row)
        }
    }

    func tableView(
        _ tableView: UITableView,
        editingStyleForRowAt indexPath: IndexPath
    ) -> UITableViewCell.EditingStyle {
        indexPath.section == Section.nowPlaying.rawValue ? .none : .delete
    }

    func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool {
        indexPath.section != Section.nowPlaying.rawValue
    }

    func tableView(
        _ tableView: UITableView,
        commit editingStyle: UITableViewCell.EditingStyle,
        forRowAt indexPath: IndexPath
    ) {
        guard editingStyle == .delete else {
            return
        }
        if indexPath.section == Section.queue.rawValue {
            player.removeFromQueue(at: indexPath.row)
        } else {
            player.removeUpcoming(at: indexPath.row)
        }
    }
}
