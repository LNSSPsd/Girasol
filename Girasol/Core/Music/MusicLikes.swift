// SPDX-License-Identifier: CC0-1.0
import Foundation

/// Which songs are liked, for the Like toggle: YouTube Music's Liked songs
/// (`LM`) read once per launch, plus whatever is liked or unliked here.
enum MusicLikes {
    private static var liked = Set<String>()
    private static var started = false
    private static let maxPages = 20

    static func isLiked(_ videoId: String) -> Bool {
        liked.contains(videoId)
    }

    static func loadIfNeeded() {
        guard !started else {
            return
        }
        started = true
        loadPage(continuation: nil, page: 0)
    }

    private static func loadPage(continuation: String?, page: Int) {
        ServiceContainer.playlists.fetchPlaylistVideos(playlistId: "LM", continuation: continuation) { result in
            DispatchQueue.main.async {
                guard case .success(let feed) = result else {
                    AppLog.player("likes: Liked songs failed on page \(page)")
                    return
                }
                liked.formUnion(feed.videos.map(\.id))
                if let next = feed.continuation, page + 1 < maxPages {
                    loadPage(continuation: next, page: page + 1)
                } else {
                    AppLog.player("likes: \(liked.count) liked songs known")
                }
            }
        }
    }

    static func set(_ videoId: String, liked isLiked: Bool, completion: @escaping (Bool) -> Void) {
        let done: (Result<Void, Error>) -> Void = { result in
            DispatchQueue.main.async {
                if case .success = result {
                    if isLiked {
                        liked.insert(videoId)
                    } else {
                        liked.remove(videoId)
                    }
                    completion(true)
                } else {
                    completion(false)
                }
            }
        }
        if isLiked {
            ServiceContainer.engagement.sendLike(videoId: videoId, completion: done)
        } else {
            ServiceContainer.engagement.removeLike(videoId: videoId, completion: done)
        }
    }
}
