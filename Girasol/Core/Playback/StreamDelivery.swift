import AVFoundation
import Foundation

/// One video/audio pair to play, and where to start.
struct DeliveryRequest {
    let info: DirectPlaybackInfo
    let video: DashFormatInfo
    let audio: DashFormatInfo
    /// Playhead to resume at — set when this replaces playback already in
    /// progress (a quality switch), nil when starting fresh.
    let resumeAt: Double?
    /// The video, when the source knows it (music's disk cache keys on it).
    var videoId: String?
}

/// How a resolved player response becomes playable bytes.
///
/// This is the second axis of playback, independent of the first. A
/// `VideoSource` decides *who we ask* — which Innertube client, with what
/// authentication — and that governs which formats, dubs and restrictions come
/// back. A `StreamDelivery` decides *how the bytes arrive*: byte-range requests
/// against `adaptiveFormats` URLs, or a SABR session.
///
/// Keeping them apart is what makes the fallback free. A source picks the
/// delivery that matches what the response actually carries, so if YouTube
/// stops handing out stream URLs — as it already did for `hlsManifestUrl` in
/// July — playback moves to SABR without a new source, a new setting, or any
/// user-visible change.
protocol StreamDelivery: AnyObject {
    /// Short name for logs and the stats overlay.
    var label: String { get }

    func prepare(
        _ request: DeliveryRequest,
        completion: @escaping (Result<PreparedPlayback, Error>) -> Void
    )
}

/// Byte-range delivery over the `adaptiveFormats` URLs: fetch each stream's
/// `sidx`, generate a byte-range HLS playlist, let AVPlayer fetch the ranges.
///
/// Subject to googlevideo's per-identity quota, which is why the machinery
/// around it (`PlaybackFacade+Identity`) exists.
final class LegacyRangeDelivery: StreamDelivery {
    let label = "range"

    private let client: PlaybackClient

    init(client: PlaybackClient) {
        self.client = client
    }

    func prepare(
        _ request: DeliveryRequest,
        completion: @escaping (Result<PreparedPlayback, Error>) -> Void
    ) {
        let info = request.info
        // Music with the disk cache on: the audio file itself, through
        // `OPAudioCache`, saved as it plays. Off: AVPlayer fetches the
        // googlevideo ranges itself, as for video.
        if AudioOnlyMode.soundOnly, let videoId = request.videoId,
           let stream = OPAudioCache.stream(
               forVideoId: videoId,
               url: client.directURL(baseURL: request.audio.url, poToken: nil),
               headers: client.streamHeaders(visitorData: info.visitorData),
               length: request.audio.contentLength,
               itag: request.audio.itag
           ) {
            Self.logLength(of: stream.item, videoId: videoId, expected: info.duration)
            completion(.success(PreparedPlayback(
                item: stream.item,
                resourceLoader: stream.loader,
                duration: info.duration
            )))
            return
        }
        let input = HLSPlaybackBuilder.BuildInput(
            videoURL: client.directURL(baseURL: request.video.url, poToken: nil),
            audioURL: client.directURL(baseURL: request.audio.url, poToken: nil),
            videoFormat: request.video,
            audioFormat: request.audio,
            headers: client.streamHeaders(visitorData: info.visitorData),
            startAt: request.resumeAt
        )
        HLSPlaybackBuilder.build(input: input) { result in
            guard let result else {
                completion(.failure(StreamDeliveryError.noStream))
                return
            }
            completion(.success(PreparedPlayback(
                item: result.playerItem,
                resourceLoader: result.loader,
                captions: info.captionTracks,
                duration: info.duration
            )))
        }
    }
}

extension LegacyRangeDelivery {
    /// The cache serves YouTube's file with its header's lengths zeroed
    /// (AVFoundation otherwise reads it as twice as long): says what
    /// AVFoundation makes of it, next to YouTube's own length.
    static func logLength(of item: AVPlayerItem, videoId: String, expected: Double?) {
        let asset = item.asset
        asset.loadValuesAsynchronously(forKeys: ["duration"]) {
            let seconds = CMTimeGetSeconds(asset.duration)
            AppLog.player(
                "audio cache: \(videoId) reads as \(String(format: "%.1f", seconds)) s,"
                    + " YouTube says \(expected.map { String(format: "%.1f", $0) } ?? "?") s"
            )
        }
    }
}

enum StreamDeliveryError: LocalizedError {
    case noStream

    var errorDescription: String? {
        "No playable stream"
    }
}
