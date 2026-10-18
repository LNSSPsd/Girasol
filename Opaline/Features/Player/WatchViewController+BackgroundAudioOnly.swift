import AVFoundation
import UIKit

// MARK: - Audio-only while backgrounded
//
// With PiP off nobody can see the picture once the app is gone, yet AVPlayer
// keeps pulling the video track for the background audio. Leaving the app
// switches to audio-only, and coming back switches to the tier that was
// playing. A video that was already audio-only before leaving stays that way:
// the switch back only undoes what the background switch did.
//
// The range delivery's main playlist lists an audio-only variant too
// (`HLSGenerator.mainPlaylist`), so there the switch is a peak bit rate cap on
// the same item: AVPlayer moves onto the audio variant by itself and the sound
// never stops. Rebuilding the item at the audio-only tier (the other sources)
// cost a hitch going out and again coming back.

extension WatchViewController {
    /// Below any video variant: AVPlayer goes as low as it can, which is the
    /// audio-only one.
    private static let audioOnlyPeakBitRate: Double = 1
    /// Generous: the cap applies from the next segment, after what is
    /// buffered already.
    private static let variantCheckDelay: TimeInterval = 40

    func enterBackgroundAudioOnlyIfNeeded() {
        guard let playerView = videoPlayerView,
              let player = playerView.player,
              !playerView.isAutoPiPEnabled,
              // A paused video stays paused: the rebuild resumes playback.
              playerView.wasPlayingOnResign || player.rate > 0,
              !AudioOnlyMode.isEnabled
        else {
            return
        }
        if let item = player.currentItem, Self.hasAudioVariant(item) {
            AppLog.player("background: audio only on the same item")
            isBackgroundCapped = true
            backgroundCapGeneration += 1
            capForBackground(item)
            return
        }
        rebuildAudioOnlyForBackground()
    }

    /// An item attached while capped (the queue moved on in the background)
    /// is capped too: it would otherwise play its picture to nobody.
    func capForBackgroundIfNeeded(_ item: AVPlayerItem) {
        guard isBackgroundCapped else {
            return
        }
        guard Self.hasAudioVariant(item) else {
            AppLog.player("background: next item has no audio variant, playing as it is")
            return
        }
        capForBackground(item)
    }

    func leaveBackgroundAudioOnlyIfNeeded() {
        if isBackgroundCapped {
            isBackgroundCapped = false
            backgroundCapGeneration += 1
            foregroundAt = Date()
            videoPlayerView?.player?.currentItem?.preferredPeakBitRate = 0
            AppLog.player("foreground: video variant allowed again")
        }
        guard isBackgroundAudioOnly else {
            return
        }
        isBackgroundAudioOnly = false
        // Still unused if the rebuild had not finished yet; the foreground
        // rebuild below must get a player of its own, bound to the layer.
        savedPlayerForBackground = nil
        // Switched back by hand (lock-screen controls cannot, but a queue
        // advance onto a source without the mode can) — nothing to undo.
        guard AudioOnlyMode.isEnabled,
              let source = playbackFacade.activeVideoSource,
              let target = AudioOnlyMode.videoQuality(in: source.availableQualities)
        else {
            return
        }
        AppLog.player("foreground: restoring \(target.label)")
        selectSourceQuality(target, source: source)
    }

    // MARK: - Private

    /// The range delivery's own playlist; SABR, live streams, files and
    /// progressive items have no audio variant.
    private static func hasAudioVariant(_ item: AVPlayerItem) -> Bool {
        (item.asset as? AVURLAsset)?.url.absoluteString == "\(HLSGenerator.scheme)://master.m3u8"
    }

    private func capForBackground(_ item: AVPlayerItem) {
        item.preferredPeakBitRate = Self.audioOnlyPeakBitRate
        observeVariant(of: item)
        let generation = backgroundCapGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.variantCheckDelay) { [weak self, weak item] in
            guard let self, let item, self.isBackgroundCapped,
                  self.backgroundCapGeneration == generation,
                  self.videoPlayerView?.player?.currentItem === item,
                  !Self.playsAudioVariant(item)
            else {
                return
            }
            AppLog.player(
                "background: still on video after \(Int(Self.variantCheckDelay)) s"
                    + " (\(Self.variantURI(item) ?? "no access log")), rebuilding audio only"
            )
            self.isBackgroundCapped = false
            item.preferredPeakBitRate = 0
            self.rebuildAudioOnlyForBackground()
        }
    }

    /// Logs each variant change of the item: when the audio one takes over
    /// in the background, and how long the picture takes to return.
    private func observeVariant(of item: AVPlayerItem) {
        if let backgroundVariantObserver {
            NotificationCenter.default.removeObserver(backgroundVariantObserver)
        }
        foregroundAt = nil
        let entered = Date()
        backgroundVariantObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemNewAccessLogEntry, object: item, queue: .main
        ) { [weak self, weak item] _ in
            guard let self, let item, let event = item.accessLog()?.events.last else {
                return
            }
            let audio = Self.playsAudioVariant(item)
            let since = self.foregroundAt.map { ("foreground", $0) } ?? ("background", entered)
            AppLog.player(String(
                format: "%@: %@ variant %.1f s after it began (%@, %.0f kbit/s)",
                since.0, audio ? "audio" : "video", Date().timeIntervalSince(since.1),
                event.uri ?? "?", event.indicatedBitrate / 1000
            ))
            if self.foregroundAt != nil, !audio {
                NotificationCenter.default.removeObserver(self.backgroundVariantObserver as Any)
                self.backgroundVariantObserver = nil
                self.foregroundAt = nil
            }
        }
    }

    private static func variantURI(_ item: AVPlayerItem) -> String? {
        item.accessLog()?.events.last?.uri
    }

    private static func playsAudioVariant(_ item: AVPlayerItem) -> Bool {
        variantURI(item)?.hasSuffix("audio.m3u8") == true
    }

    /// The other sources: the item is rebuilt at the audio-only tier.
    private func rebuildAudioOnlyForBackground() {
        guard let player = videoPlayerView?.player,
              let source = playbackFacade.activeVideoSource,
              source.availableQualities.contains(where: { $0.id == AudioOnlyMode.qualityID })
        else {
            return
        }
        AppLog.player("background: switching to audio only")
        isBackgroundAudioOnly = true
        // Reuse the player the view has just detached from its layer: a fresh
        // one would be bound to the layer again, and iOS below 15 pauses a
        // layer-backed player in the background.
        savedPlayerForBackground = player
        selectSourceQuality(AudioOnlyMode.quality, source: source)
    }
}
