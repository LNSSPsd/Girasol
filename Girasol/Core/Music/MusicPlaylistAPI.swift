// SPDX-License-Identifier: CC0-1.0
import Foundation

/// Music mode's playlist calls. With the web account they go through
/// YouTube Music: that is the account that creates playlists, and it reads
/// empty and private ones the TV client fails on. Without it — or when
/// YouTube Music refuses — through the TV sign-in, as video mode does.
/// Completions run on any queue.
enum MusicPlaylistAPI {
    static func addOptions(videoId: String, completion: @escaping (Result<[PlaylistAddOption], Error>) -> Void) {
        YTMusicPublic.addToPlaylistOptions(videoId: videoId) { options in
            guard let options else {
                ServiceContainer.playlists.fetchAddToPlaylistOptions(videoId: videoId, completion: completion)
                return
            }
            completion(.success(options))
        }
    }

    static func edit(
        playlistId: String,
        actions: [[String: Any]],
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        YTMusicPublic.editPlaylist(playlistId, actions: actions) { ok in
            guard ok == true else {
                ServiceContainer.engagement.editPlaylist(playlistId: playlistId, actions: actions, completion: completion)
                return
            }
            completion(.success(()))
        }
    }

    /// Adds a song even when the playlist has it already. The new row's
    /// entry id when YouTube Music named it.
    static func add(videoId: String, to playlistId: String, completion: @escaping (Result<String?, Error>) -> Void) {
        YTMusicPublic.addToPlaylist(playlistId, videoId: videoId) { entryId in
            guard let entryId else {
                let actions: [[String: Any]] = [
                    ["action": "ACTION_ADD_VIDEO", "addedVideoId": videoId, "dedupeOption": "DEDUPE_OPTION_SKIP"]
                ]
                ServiceContainer.engagement.editPlaylist(playlistId: playlistId, actions: actions) {
                    completion($0.map { nil })
                }
                return
            }
            completion(.success(entryId.isEmpty ? nil : entryId))
        }
    }

    static func delete(id: String, completion: @escaping (Result<Void, Error>) -> Void) {
        YTMusicPublic.deletePlaylist(id) { ok in
            guard ok == true else {
                ServiceContainer.music.deletePlaylist(id: id, completion: completion)
                return
            }
            completion(.success(()))
        }
    }
}
