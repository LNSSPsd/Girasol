import AVFoundation

/// How the range delivery's main playlist lists its audio-only variant, the
/// one leaving the app moves onto without rebuilding the item
/// (`WatchViewController+BackgroundAudioOnly`).
///
/// AVPlayer on iOS 14.3 refused one way of writing it outright (errors
/// -11800 / -12642 on every video), and nothing here can run AVPlayer. So
/// the first video of a launch, on Wi-Fi, has every form loaded in a muted
/// player of its own; a form counts once AVPlayer accepts it and a peak bit
/// rate cap moves it onto the audio variant. Until one has, real items open
/// the plain playlist and leaving the app rebuilds as before.
enum HLSAudioVariant {
    enum Form: String, CaseIterable {
        /// The rendition's own playlist, naming the audio group: the sound
        /// should carry on across the switch.
        case sharedWithGroup = "shared+group"
        case own
        case ownWithGroup = "own+group"
        /// Refused on the device; kept as the control (accepted here, the probe
        /// would not tell anything).
        case shared

        func variant(codecs: String, bandwidth: Int) -> HLSGenerator.AudioOnlyVariant {
            let path: String
            let joinsGroup: Bool
            switch self {
            case .sharedWithGroup:
                path = "audio.m3u8"
                joinsGroup = true
            case .own:
                path = ownPath
                joinsGroup = false
            case .ownWithGroup:
                path = ownPath
                joinsGroup = true
            case .shared:
                path = "audio.m3u8"
                joinsGroup = false
            }
            return HLSGenerator.AudioOnlyVariant(
                codecs: codecs, bandwidth: bandwidth,
                uri: "\(HLSGenerator.scheme)://\(path)", joinsGroup: joinsGroup
            )
        }
    }

    static let ownPath = "audio-variant.m3u8"
    /// What an item opens once a form is proven: a name of its own, so an
    /// item tells by its URL whether it has the variant.
    static let entryPath = "master-variant.m3u8"
    private static let provenKey = "hlsAudioVariant.proven"

    static func probePath(_ form: Form) -> String {
        "probe-\(form.rawValue).m3u8"
    }

    /// The form AVPlayer accepted and switched on, on this device.
    static var proven: Form? {
        UserDefaults.standard.string(forKey: provenKey).flatMap(Form.init(rawValue:))
    }

    /// Whether the access log's variant is the audio-only one.
    static func isAudioVariant(_ uri: String?) -> Bool {
        guard let uri else {
            return false
        }
        return uri.hasSuffix("audio.m3u8") || uri.hasSuffix(ownPath)
    }

    private static var probedThisLaunch = false

    /// Any queue. Once per launch, on Wi-Fi, until a form is proven.
    static func probeIfDue(loader: HLSPlaylistLoader, headers: [String: String]) {
        DispatchQueue.main.async {
            guard !probedThisLaunch, proven == nil, !NetworkType.isCellular, !NetworkType.isOffline else {
                return
            }
            probedThisLaunch = true
            // After the real item has had its start.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                AppLog.hls("audio variant probe: \(Form.allCases.count) forms")
                run(Form.allCases[...], loader: loader, headers: headers, passed: [])
            }
        }
    }

    /// One form after another, so at most one probe fetches at a time.
    private static func run(
        _ forms: ArraySlice<Form>,
        loader: HLSPlaylistLoader,
        headers: [String: String],
        passed: [Form]
    ) {
        guard let form = forms.first else {
            // The first in `Form` order wins: sharing the rendition's URI is
            // what should keep the sound unbroken.
            let winner = Form.allCases.first { passed.contains($0) && $0 != .shared }
            if let winner {
                UserDefaults.standard.set(winner.rawValue, forKey: provenKey)
            }
            AppLog.hls(
                "audio variant probe done: passed \(passed.map(\.rawValue)); "
                    + (winner.map { "using \($0.rawValue) from the next video" } ?? "none used")
            )
            return
        }
        let probe = Probe(form: form, loader: loader, headers: headers)
        probe.start { ok in
            run(forms.dropFirst(), loader: loader, headers: headers, passed: ok ? passed + [form] : passed)
            _ = probe
        }
    }

    /// A muted player with no layer on one form's playlist: accepted? moved
    /// to the audio variant under the cap? back to video once it is lifted?
    private final class Probe {
        private static let readyTimeout: TimeInterval = 15
        private static let switchTimeout: TimeInterval = 25

        let form: Form
        private let loader: HLSPlaylistLoader
        private let item: AVPlayerItem
        private let player: AVPlayer
        private var status: NSKeyValueObservation?
        private var accessLog: NSObjectProtocol?
        private var finish: ((Bool) -> Void)?
        private var phase = 0
        private var phaseStarted = Date()

        init(form: Form, loader: HLSPlaylistLoader, headers: [String: String]) {
            self.form = form
            self.loader = loader
            let url = URL(string: "\(HLSGenerator.scheme)://\(HLSAudioVariant.probePath(form))")!
            let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
            asset.resourceLoader.setDelegate(loader, queue: loader.loaderQueue)
            item = AVPlayerItem(asset: asset)
            item.preferredForwardBufferDuration = 4
            player = AVPlayer(playerItem: item)
            player.isMuted = true
        }

        func start(completion: @escaping (Bool) -> Void) {
            finish = completion
            phaseStarted = Date()
            status = item.observe(\.status) { [weak self] item, _ in
                DispatchQueue.main.async { self?.statusChanged(item.status) }
            }
            accessLog = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemNewAccessLogEntry, object: item, queue: .main
            ) { [weak self] _ in
                self?.variantChanged()
            }
            let phaseAtStart = phase
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.readyTimeout) { [weak self] in
                guard let self, self.phase == phaseAtStart else {
                    return
                }
                self.log("no answer in \(Int(Self.readyTimeout)) s")
                self.end(false)
            }
        }

        private func statusChanged(_ status: AVPlayerItem.Status) {
            guard phase == 0 else {
                return
            }
            switch status {
            case .failed:
                let error = item.error as NSError?
                let underlying = error?.userInfo[NSUnderlyingErrorKey] as? NSError
                log("refused (\(error?.code ?? 0) / \(underlying?.code ?? 0))")
                end(false)
            case .readyToPlay:
                log("accepted, on \(variant ?? "?"); capping")
                enter(phase: 1)
                item.preferredPeakBitRate = 1
                player.play()
                // Without a layer AVPlayer may be on it already.
                variantChanged()
                timeout(phase: 1) { [weak self] in
                    self?.log("stayed on \(self?.variant ?? "?") under the cap")
                    self?.end(false)
                }
            default:
                break
            }
        }

        private func variantChanged() {
            let audio = HLSAudioVariant.isAudioVariant(variant)
            let seconds = String(format: "%.1f", Date().timeIntervalSince(phaseStarted))
            if phase == 1, audio {
                log("moved to the audio variant \(seconds) s into the cap; lifting it")
                enter(phase: 2)
                item.preferredPeakBitRate = 0
                timeout(phase: 2) { [weak self] in
                    self?.log("no video \(Int(Self.switchTimeout)) s after the cap was lifted (no layer: may be normal)")
                    self?.end(true)
                }
            } else if phase == 2, !audio {
                log("video again \(seconds) s after the cap was lifted")
                end(true)
            }
        }

        private var variant: String? {
            item.accessLog()?.events.last?.uri
        }

        private func enter(phase: Int) {
            self.phase = phase
            phaseStarted = Date()
        }

        private func timeout(phase: Int, _ body: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.switchTimeout) { [weak self] in
                guard self?.phase == phase else {
                    return
                }
                body()
            }
        }

        private func log(_ text: String) {
            AppLog.hls("audio variant \(form.rawValue): \(text)")
        }

        private func end(_ ok: Bool) {
            guard let finish else {
                return
            }
            self.finish = nil
            phase = -1
            status = nil
            if let accessLog {
                NotificationCenter.default.removeObserver(accessLog)
            }
            player.pause()
            player.replaceCurrentItem(with: nil)
            finish(ok)
        }
    }
}
