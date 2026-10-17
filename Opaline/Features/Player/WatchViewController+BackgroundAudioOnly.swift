import UIKit

// MARK: - Audio-only while backgrounded
//
// With PiP off nobody can see the picture once the app is gone, yet AVPlayer
// keeps pulling the video track for the background audio. Leaving the app
// switches to audio-only — the audio-only entry playlist never requests a
// video segment — and coming back switches to the tier that was playing.
// A video that was already audio-only before leaving stays that way: the
// switch back only undoes what the background switch did.

extension WatchViewController {
    func enterBackgroundAudioOnlyIfNeeded() {
        guard let playerView = videoPlayerView,
              let player = playerView.player,
              !playerView.isAutoPiPEnabled,
              // A paused video stays paused: the rebuild resumes playback.
              playerView.wasPlayingOnResign || player.rate > 0,
              !AudioOnlyMode.isEnabled,
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

    func leaveBackgroundAudioOnlyIfNeeded() {
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
}
