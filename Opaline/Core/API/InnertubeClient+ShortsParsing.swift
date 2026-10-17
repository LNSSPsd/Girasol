import Foundation

// MARK: - Shorts tiles

/// Shorts arrive as their own tiles on a channel's page; these turn them into
/// ordinary `Video`s (flagged `isShort`) that play in the normal player.
extension InnertubeClient {
    /// A `reelWatchEndpoint` carries the videoId and a poster frame but no
    /// title or channel — those arrive with the watch page.
    static func shortsVideo(
        fromReelWatchEndpoint endpoint: [String: Any]
    ) -> Video? {
        guard let videoId = endpoint[JSONKey.videoId] as? String else {
            return nil
        }
        let thumbnails = endpoint.digArray("thumbnail", JSONKey.thumbnails)
        let thumbnail = thumbnails?.last?[JSONKey.url] as? String
        return Video(
            id: videoId,
            title: "",
            channelId: nil,
            channelName: "",
            channelAvatarURL: nil,
            thumbnailURL: thumbnail ?? "",
            viewCount: nil,
            publishedAt: nil,
            duration: nil,
            isShort: true
        )
    }

    /// Parses a `shortsLockupViewModel` grid item.
    static func parseShortsLockup(_ lockup: [String: Any]) -> Video? {
        guard let endpoint = lockup.digDict(
            "onTap", "innertubeCommand", "reelWatchEndpoint"
        ), let base = shortsVideo(fromReelWatchEndpoint: endpoint) else {
            return nil
        }
        let meta = lockup.digDict("overlayMetadata")
        let sources = lockup.digArray(
            "thumbnailViewModel", "image", "sources"
        )
        let thumbnail = sources?.first?[JSONKey.url] as? String
        return Video(
            id: base.id,
            title: meta.flatMap {
                ($0["primaryText"] as? [String: Any])?["content"] as? String
            } ?? "",
            channelId: nil,
            channelName: "",
            channelAvatarURL: nil,
            thumbnailURL: thumbnail ?? base.thumbnailURL,
            viewCount: meta.flatMap {
                ($0["secondaryText"] as? [String: Any])?["content"] as? String
            },
            publishedAt: nil,
            duration: nil,
            isShort: true
        )
    }
}
