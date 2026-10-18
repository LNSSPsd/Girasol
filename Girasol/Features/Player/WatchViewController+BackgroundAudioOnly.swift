// SPDX-License-Identifier: CC0-1.0
import UIKit

// MARK: - Audio-only while backgrounded
//
// With PiP off nobody can see the picture once the app is gone, yet AVPlayer
// keeps pulling the video track for the background audio. Leaving the app
// switches to audio-only — the audio-only entry playlist never requests a
// video segment — and coming back switches to the tier that was playing.
// Both switches hand over between two players in step
// (`WatchViewController+Handover`): replacing the item on the one player
// left a short hitch each way.
//
// Not possible in one item (probed on the device): AVPlayer accepts
// an audio-only variant in the main playlist only with `AUDIO="audio"`, but
// no peak bit rate cap ever moves it onto that variant.
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
        // The new player is never bound to the layer the view has just
        // detached: iOS below 15 pauses a layer-backed player in the
        // background.
        handsOverNextItem = true
        playerView.layerWaitsForHandover = true
        selectSourceQuality(AudioOnlyMode.quality, source: source)
    }

    func leaveBackgroundAudioOnlyIfNeeded() {
        guard isBackgroundAudioOnly else {
            return
        }
        isBackgroundAudioOnly = false
        // Switched back by hand (lock-screen controls cannot, but a queue
        // advance onto a source without the mode can) — nothing to undo.
        guard AudioOnlyMode.isEnabled,
              let source = playbackFacade.activeVideoSource,
              let target = AudioOnlyMode.videoQuality(in: source.availableQualities)
        else {
            return
        }
        AppLog.player("foreground: restoring \(target.label)")
        handsOverNextItem = true
        videoPlayerView?.layerWaitsForHandover = true
        selectSourceQuality(target, source: source)
    }
}
