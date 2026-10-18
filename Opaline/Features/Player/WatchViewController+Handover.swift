import AVFoundation
import UIKit

// MARK: - Handover between two players
//
// Replacing the item on the playing player (the background audio-only switch
// and the way back) stops the sound until the new item has buffered: a short
// hitch each way. Instead the new item gets a player of its own, is sought a
// little ahead of where playback stands and prerolled, and then both players
// are given the same moment on the host clock — the new one starts there at
// that media time, the old one stops there (`setRate(_:time:atHostTime:)`).

/// One handover in progress; the view still shows `old` until the switch.
final class PlayerHandover {
    let item: AVPlayerItem
    let player: AVPlayer
    let old: AVPlayer
    var status: NSKeyValueObservation?
    var attempt = 0
    var done = false

    init(item: AVPlayerItem, old: AVPlayer) {
        self.item = item
        self.old = old
        player = AVPlayer(playerItem: item)
        // Required for a start at a host time.
        player.automaticallyWaitsToMinimizeStalling = false
        player.volume = old.volume
        player.isMuted = old.isMuted
    }
}

extension WatchViewController {
    /// Room for the seek and preroll; doubled on each retry.
    private static let handoverLead: Double = 0.6
    /// The view moves to the new player this long before the switch, so
    /// the old player's stop is never seen as a pause.
    private static let viewLead: Double = 0.1
    private static let handoverTimeout: TimeInterval = 8

    func handOver(to item: AVPlayerItem, from old: AVPlayer) {
        handover?.status = nil
        PlaybackBufferPolicy.configure(item: item)
        let handover = PlayerHandover(item: item, old: old)
        self.handover = handover
        handover.status = item.observe(\.status, options: [.initial, .new]) { [weak self, weak handover] observed, _ in
            DispatchQueue.main.async {
                guard let self, let handover, self.handover === handover, !handover.done else {
                    return
                }
                switch observed.status {
                case .readyToPlay:
                    handover.status = nil
                    self.synchronize(handover)
                case .failed:
                    // Its failure is the screen's to handle, as before.
                    AppLog.player("handover: new item failed, switching as it is")
                    self.switchUnsynced(handover)
                default:
                    break
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.handoverTimeout) { [weak self, weak handover] in
            guard let self, let handover, self.handover === handover, !handover.done else {
                return
            }
            AppLog.player("handover: not ready in \(Int(Self.handoverTimeout)) s, switching as it is")
            self.switchUnsynced(handover)
        }
    }

    // MARK: - Private

    private func synchronize(_ handover: PlayerHandover) {
        let old = handover.old
        let rate = old.rate
        // Paused, scrubbing speed or AirPlay: nothing to keep in step (and a
        // host-time start is not for external playback).
        guard rate > 0, !old.isExternalPlaybackActive, old.currentItem != nil else {
            switchUnsynced(handover)
            return
        }
        let lead = Self.handoverLead * pow(2, Double(handover.attempt))
        let target = CMTimeAdd(old.currentTime(), CMTime(seconds: lead * Double(rate), preferredTimescale: 90_000))
        let fresh = handover.player
        fresh.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            DispatchQueue.main.async {
                guard let self, self.handover === handover, !handover.done else {
                    return
                }
                guard finished else {
                    self.switchUnsynced(handover)
                    return
                }
                fresh.preroll(atRate: rate) { _ in
                    DispatchQueue.main.async {
                        guard self.handover === handover, !handover.done else {
                            return
                        }
                        self.start(handover, at: target, rate: rate)
                    }
                }
            }
        }
    }

    private func start(_ handover: PlayerHandover, at target: CMTime, rate: Float) {
        let old = handover.old
        let fresh = handover.player
        let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
        let ahead = CMTimeGetSeconds(CMTimeSubtract(target, old.currentTime())) / Double(rate)
        guard old.rate == rate, ahead > Self.viewLead + 0.05 else {
            // The old player moved past the target (slow preroll) or changed
            // speed: again, further ahead.
            handover.attempt += 1
            guard handover.attempt < 3 else {
                AppLog.player("handover: could not get ahead of playback, switching as it is")
                switchUnsynced(handover)
                return
            }
            synchronize(handover)
            return
        }
        let hostTime = CMTimeAdd(hostNow, CMTime(seconds: ahead, preferredTimescale: 1_000_000_000))
        old.automaticallyWaitsToMinimizeStalling = false
        fresh.setRate(rate, time: target, atHostTime: hostTime)
        old.setRate(0, time: .invalid, atHostTime: hostTime)
        AppLog.player(String(
            format: "handover: in step at %.2f s, %.2f s from now (attempt %d)",
            CMTimeGetSeconds(target), ahead, handover.attempt + 1
        ))
        DispatchQueue.main.asyncAfter(deadline: .now() + ahead - Self.viewLead) { [weak self] in
            self?.finish(handover)
        }
        // How far apart they were: the new player's clock against where the
        // old one would have been.
        DispatchQueue.main.asyncAfter(deadline: .now() + ahead + 1) {
            let expected = CMTimeGetSeconds(target) + Double(rate)
            let actual = CMTimeGetSeconds(fresh.currentTime())
            AppLog.player(String(format: "handover: 1 s in, %+.0f ms off", (actual - expected) * 1000))
        }
    }

    /// The fallback: the old player stops now, the new one starts where it
    /// stood (a short gap, as the item replacement had).
    private func switchUnsynced(_ handover: PlayerHandover) {
        let old = handover.old
        let wasPlaying = old.rate > 0
        let position = old.currentTime()
        old.pause()
        handover.player.automaticallyWaitsToMinimizeStalling = true
        handover.player.seek(to: position, toleranceBefore: .zero, toleranceAfter: .zero)
        if wasPlaying {
            handover.player.playImmediately(atRate: videoPlayerView?.playbackSpeed ?? 1)
        }
        finish(handover)
    }

    /// The view, Now Playing and the item observers move to the new player;
    /// the old one is let go once it has stopped.
    private func finish(_ handover: PlayerHandover) {
        guard !handover.done else {
            return
        }
        handover.done = true
        handover.status = nil
        if self.handover === handover {
            self.handover = nil
        }
        let old = handover.old
        if let oldItem = old.currentItem {
            stopObservingPlayerItem(oldItem)
        }
        playerStatusLabel.isHidden = true
        videoPlayerView?.handOver(to: handover.player)
        NowPlayingService.shared.rebindPlayer(handover.player)
        // Its ready callback (Now Playing session, resume bookkeeping) runs
        // now, against the player the view shows.
        startObservingPlayerItem(handover.item)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            old.pause()
            old.replaceCurrentItem(with: nil)
        }
    }
}
