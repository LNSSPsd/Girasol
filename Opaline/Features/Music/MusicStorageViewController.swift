// SPDX-License-Identifier: CC0-1.0
import UIKit

/// Library → Downloads → Storage: what music downloads take, in all and per
/// album or playlist (a song in two of them counts in both), against the
/// space left on the device. Swipe a collection to remove its downloads;
/// the last row removes every music download. Video downloads share the
/// store and are left out (a music download has no video track).
final class MusicStorageViewController: MusicListViewController {
    private struct Row {
        let collection: Playlist
        let tracks: [Video]
        let bytes: Int64
        let saved: Int
    }

    private var rows: [Row] = []
    private var totalBytes: Int64 = 0
    private var songCount = 0
    private var songs: [Video] = []
    private var freeBytes: Int64?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Storage"
        NotificationCenter.default.addObserver(
            self, selector: #selector(measure), name: DownloadStore.didChangeNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(measure), name: .OPAudioCacheDidChange, object: nil
        )
        measure()
    }

    private var cacheSongs = 0
    private var cacheBytes: UInt64 = 0

    /// Sizes come from the files, off the main thread.
    @objc
    private func measure() {
        spinner.startAnimating()
        OPAudioCache.measure { [weak self] complete, bytes in
            self?.cacheSongs = Int(complete)
            self?.cacheBytes = bytes
            self?.tableView.reloadData()
        }
        let collections = MusicDownloads.collections()
        let downloads = DownloadStore.downloads()
        DispatchQueue.global(qos: .userInitiated).async {
            let songs = downloads.filter { MusicDownloads.isAudioOnly($0.id) }
            var sizes: [String: Int64] = [:]
            func size(_ id: String) -> Int64 {
                if let known = sizes[id] {
                    return known
                }
                let bytes = MusicDownloads.size(of: id)
                sizes[id] = bytes
                return bytes
            }
            let rows = collections.map { collection -> Row in
                let tracks = MusicDownloads.tracks(ofCollection: collection.id)
                let saved = tracks.filter { size($0.id) > 0 }
                return Row(
                    collection: collection, tracks: tracks,
                    bytes: saved.reduce(0) { $0 + size($1.id) }, saved: saved.count
                )
            }
            let total = songs.reduce(Int64(0)) { $0 + size($1.id) }
            let free = (try? URL(fileURLWithPath: NSHomeDirectory())
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage
            DispatchQueue.main.async {
                self.spinner.stopAnimating()
                self.rows = rows.sorted { $0.bytes > $1.bytes }
                self.totalBytes = total
                self.songCount = songs.count
                self.songs = songs
                self.freeBytes = free
                self.tableView.reloadData()
            }
        }
    }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        4
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0:
            return 1
        case 1:
            return rows.count
        case 3:
            return 1
        default:
            return songCount > 0 ? 1 : 0
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if section == 3 {
            return "Kept as played"
        }
        return section == 1 && !rows.isEmpty ? "Albums and playlists" : nil
    }

    override func tableView(
        _ tableView: UITableView,
        willDisplay cell: UITableViewCell,
        forRowAt indexPath: IndexPath
    ) {
        guard let cell = cell as? MusicItemCell else {
            return
        }
        switch indexPath.section {
        case 0:
            let free = freeBytes.map { " · \(Self.format($0)) free on this device" } ?? ""
            cell.configure(
                title: "\(Self.format(totalBytes)) in \(songCount) \(songCount == 1 ? "song" : "songs")",
                subtitle: "Music downloads" + free,
                artworkURL: nil
            )
        case 1:
            let row = rows[indexPath.row]
            cell.configure(
                title: row.collection.title,
                subtitle: "\(Self.format(row.bytes)) · \(row.saved) of \(row.tracks.count) songs saved",
                artworkURL: row.collection.thumbnailURL
            )
        case 3:
            let budget = OPMusicSettings.title(forDiskCacheMegabytes: OPMusicSettings.diskCacheMegabytes)
            cell.configure(
                title: "\(Self.format(Int64(cacheBytes))) · \(cacheSongs) whole \(cacheSongs == 1 ? "song" : "songs") ◌",
                subtitle: OPAudioCache.isEnabled()
                    ? "Up to \(budget) (Music settings) · tap to empty" : "Off in Music settings · tap to empty",
                artworkURL: nil
            )
        default:
            cell.configure(title: "Remove all music downloads", subtitle: "Video downloads stay", artworkURL: nil)
        }
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard indexPath.section == 1 else {
            return nil
        }
        let row = rows[indexPath.row]
        let remove = UIContextualAction(style: .destructive, title: "Remove") { _, _, done in
            MusicDownloads.remove(collection: row.collection, tracks: row.tracks)
            done(true)
        }
        remove.image = UIImage(systemName: "trash")
        return UISwipeActionsConfiguration(actions: [remove])
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch indexPath.section {
        case 1:
            navigationController?.pushViewController(
                MusicCollectionViewController(collection: rows[indexPath.row].collection), animated: true
            )
        case 2:
            confirmRemoveAll(from: tableView.cellForRow(at: indexPath))
        case 3:
            confirmClearCache(from: tableView.cellForRow(at: indexPath))
        default:
            break
        }
    }

    private func confirmClearCache(from cell: UIView?) {
        let sheet = UIAlertController(
            title: "Empty the cache?",
            message: "Songs kept as they played (\(Self.format(Int64(cacheBytes)))). Downloads stay.",
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: "Empty", style: .destructive) { _ in
            OPAudioCache.clear()
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = cell ?? view
        present(sheet, animated: true)
    }

    private func confirmRemoveAll(from cell: UIView?) {
        let sheet = UIAlertController(
            title: "Remove all downloads?",
            message: "\(songCount) songs, \(Self.format(totalBytes)). They will need the network again.",
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: "Remove all", style: .destructive) { _ in
            for row in self.rows {
                MusicDownloads.remove(collection: row.collection, tracks: row.tracks)
            }
            MusicDownloads.remove(self.songs)
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = cell ?? view
        present(sheet, animated: true)
    }
}
