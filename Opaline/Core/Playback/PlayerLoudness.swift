import Foundation

/// How much louder than YouTube's loudness target each video is, in dB, as
/// its `/player` response says: the chosen audio format's `loudnessDb`, else
/// `playerConfig.audioConfig.loudnessDb`, else the track's measured loudness
/// minus the target. Noted for every response parsed, read by music mode to
/// level songs the way YouTube's own players do (louder ones turned down,
/// quieter ones left as they are). Kept in the defaults, so a downloaded
/// song played offline (no `/player`) is levelled too.
enum PlayerLoudness {
    private static let key = "playerLoudness_levels"
    private static let lock = NSLock()
    private static var levels = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]

    static func record(from json: [String: Any], audioFormat: [String: Any]?) {
        guard let videoId = json.digString("videoDetails", "videoId") else {
            AppLog.player("loudness: response names no video")
            return
        }
        let config = (json["playerConfig"] as? [String: Any])?["audioConfig"] as? [String: Any]
        var level = number(audioFormat?["loudnessDb"]) ?? number(config?["loudnessDb"])
        if level == nil,
           let track = number(config?["trackAbsoluteLoudnessLkfs"]),
           let target = number(config?["loudnessTargetLkfs"]) {
            level = track - target
        }
        AppLog.player("loudness for \(videoId): " + (level.map { String(format: "%+.1f dB", $0) } ?? "not given"))
        guard let level else {
            return
        }
        lock.lock()
        levels[videoId] = level
        let stored = levels
        lock.unlock()
        UserDefaults.standard.set(stored, forKey: key)
    }

    static func level(of videoId: String) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        return levels[videoId]
    }

    /// The player volume that brings the video down to the target; never
    /// above 1 (AVPlayer cannot amplify).
    static func volume(for videoId: String) -> Float {
        guard let level = level(of: videoId), level > 0 else {
            return 1
        }
        return Float(pow(10, -level / 20))
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        return (value as? String).flatMap(Double.init)
    }
}
