import AVFoundation

/// Builds HLS playlists from DASH adaptive format info.
enum HLSPlaybackBuilder {
    struct Result {
        let playerItem: AVPlayerItem
        let loader: HLSPlaylistLoader
    }

    struct BuildInput {
        let videoURL: URL
        let audioURL: URL
        let videoFormat: DashFormatInfo
        let audioFormat: DashFormatInfo
        let headers: [String: String]
        /// Where the player should begin — the saved playhead on a resume,
        /// the current one on a rebuild, nil from the start of the video.
        var startAt: Double?
    }

    struct RangeRequest {
        let url: URL
        let start: Int64
        let end: Int64
        let headers: [String: String]
    }

    // MARK: - Public API

    /// Fetches SIDX data, generates HLS playlists, and
    /// returns a ready-to-play AVPlayerItem.
    static func build(
        input: BuildInput,
        completion: @escaping (Result?) -> Void
    ) {
        let startTime = CACurrentMediaTime()
        probeIdentity(input: input) { healthy in
            guard healthy else {
                completion(nil)
                return
            }
            // Read once: the flag may change while the requests run.
            let soundOnly = AudioOnlyMode.soundOnly
            fetchSidxPair(input: input, soundOnly: soundOnly) { videoData, audioData in
                let result = processSidxData(
                    input: input,
                    videoData: videoData,
                    audioData: audioData,
                    soundOnly: soundOnly,
                    startTime: startTime
                )
                completion(result)
            }
        }
    }
}

// MARK: - Private Helpers

private extension HLSPlaybackBuilder {
    static func fetchSidxPair(
        input: BuildInput,
        soundOnly: Bool,
        completion: @escaping (Data?, Data?) -> Void
    ) {
        let group = DispatchGroup()
        var videoData: Data?
        var audioData: Data?
        if !soundOnly {
            group.enter()
            fetchSidxData(
                url: input.videoURL,
                format: input.videoFormat,
                headers: input.headers
            ) { data in
                videoData = data
                group.leave()
            }
        }
        group.enter()
        fetchSidxData(
            url: input.audioURL,
            format: input.audioFormat,
            headers: input.headers
        ) { data in
            audioData = data
            group.leave()
        }
        let queue = DispatchQueue.global(qos: .userInitiated)
        group.notify(queue: queue) {
            completion(videoData, audioData)
        }
    }

    static func fetchSidxData(
        url: URL,
        format: DashFormatInfo,
        headers: [String: String],
        completion: @escaping (Data?) -> Void
    ) {
        let req = RangeRequest(
            url: url,
            start: Int64(format.indexRangeStart),
            end: Int64(format.indexRangeEnd),
            headers: headers
        )
        fetchRangeData(request: req, completion: completion)
    }

    static func processSidxData(
        input: BuildInput,
        videoData: Data?,
        audioData: Data?,
        soundOnly: Bool,
        startTime: CFTimeInterval
    ) -> Result? {
        guard let aData = audioData, soundOnly || videoData != nil else {
            AppLog.hls("failed to fetch sidx data")
            return nil
        }
        let parsed: (video: [SidxSegment], audio: [SidxSegment])
        if let vData = videoData {
            guard let pair = parseSidxPair(videoData: vData, audioData: aData) else {
                return nil
            }
            parsed = pair
        } else {
            guard let audio = HLSGenerator.parseSidx(data: aData) else {
                AppLog.hls("failed to parse audio sidx")
                return nil
            }
            parsed = ([], audio)
        }
        logSidxParsed(
            parsed.video,
            parsed.audio,
            since: startTime
        )
        return buildPlayerItem(
            input: input,
            videoSegments: parsed.video,
            audioSegments: parsed.audio,
            startTime: startTime
        )
    }

    static func parseSidxPair(
        videoData: Data,
        audioData: Data
    ) -> (video: [SidxSegment], audio: [SidxSegment])? {
        guard let vSegs = HLSGenerator.parseSidx(
            data: videoData
        ) else {
            AppLog.hls("failed to parse video sidx")
            return nil
        }
        guard let aSegs = HLSGenerator.parseSidx(
            data: audioData
        ) else {
            AppLog.hls("failed to parse audio sidx")
            return nil
        }
        return (vSegs, aSegs)
    }

    static func logSidxParsed(
        _ videoSegs: [SidxSegment],
        _ audioSegs: [SidxSegment],
        since startTime: CFTimeInterval
    ) {
        let elapsed = CACurrentMediaTime() - startTime
        // Totals from the segment index: a timeline that does not match the
        // track's real length puts everything timed against it off.
        let msg = String(
            format: "sidx parsed in %.1fs — v:%d (%.2fs) a:%d (%.2fs, first %.2fs)",
            elapsed,
            videoSegs.count,
            videoSegs.reduce(0) { $0 + $1.duration },
            audioSegs.count,
            audioSegs.reduce(0) { $0 + $1.duration },
            audioSegs.first?.duration ?? 0
        )
        AppLog.hls(msg)
    }

    static func buildPlayerItem(
        input: BuildInput,
        videoSegments: [SidxSegment],
        audioSegments: [SidxSegment],
        startTime: CFTimeInterval
    ) -> Result? {
        // Read once: a probe may prove a form while this build runs.
        let variant = AudioOnlyMode.soundOnly ? nil : HLSAudioVariant.proven
        let loader = createPlaylistLoader(
            input: input,
            videoSegments: videoSegments,
            audioSegments: audioSegments,
            variant: variant
        )
        let elapsed = CACurrentMediaTime() - startTime
        let msg = String(
            format: "playlists ready in %.1fs",
            elapsed
        )
        AppLog.hls(msg)
        let entry = variant != nil && !AudioOnlyMode.isEnabled
            ? HLSAudioVariant.entryPath : AudioOnlyMode.entryPlaylist
        let urlStr = "\(HLSGenerator.scheme)://\(entry)"
        guard let plURL = URL(string: urlStr) else {
            return nil
        }
        let opts: [String: Any] = [
            "AVURLAssetHTTPHeaderFieldsKey": input.headers
        ]
        let asset = AVURLAsset(url: plURL, options: opts)
        asset.resourceLoader.setDelegate(
            loader,
            queue: loader.loaderQueue
        )
        let item = AVPlayerItem(asset: asset)
        PlaybackBufferPolicy.configure(item: item)
        if !AudioOnlyMode.soundOnly {
            HLSAudioVariant.probeIfDue(loader: loader, headers: input.headers)
        }
        return Result(playerItem: item, loader: loader)
    }

    static func createPlaylistLoader(
        input: BuildInput,
        videoSegments: [SidxSegment],
        audioSegments: [SidxSegment],
        variant: HLSAudioVariant.Form?
    ) -> HLSPlaylistLoader {
        let loader = HLSPlaylistLoader()
        registerMediaPlaylists(
            on: loader,
            input: input,
            videoSegments: videoSegments,
            audioSegments: audioSegments
        )
        registerMainPlaylists(
            on: loader,
            input: input,
            videoSegments: videoSegments,
            audioSegments: audioSegments,
            variant: variant
        )
        return loader
    }

    static func registerMediaPlaylists(
        on loader: HLSPlaylistLoader,
        input: BuildInput,
        videoSegments: [SidxSegment],
        audioSegments: [SidxSegment]
    ) {
        let vidFmt = input.videoFormat
        let audFmt = input.audioFormat
        let videoPl = HLSGenerator.mediaPlaylist(
            url: input.videoURL,
            initBytes: vidFmt.initRangeEnd + 1,
            dataStartOffset: Int64(vidFmt.indexRangeEnd + 1),
            segments: videoSegments,
            startAt: input.startAt
        )
        let audioPl = HLSGenerator.mediaPlaylist(
            url: input.audioURL,
            initBytes: audFmt.initRangeEnd + 1,
            dataStartOffset: Int64(audFmt.indexRangeEnd + 1),
            segments: audioSegments,
            startAt: input.startAt
        )
        loader.register(path: "video.m3u8", content: videoPl)
        loader.register(path: "audio.m3u8", content: audioPl)
        // The audio-only variant's own copy, for the forms that do not share
        // the rendition's URI.
        loader.register(path: HLSAudioVariant.ownPath, content: audioPl)
    }

    static func registerMainPlaylists(
        on loader: HLSPlaylistLoader,
        input: BuildInput,
        videoSegments: [SidxSegment],
        audioSegments: [SidxSegment],
        variant: HLSAudioVariant.Form?
    ) {
        let vidFmt = input.videoFormat
        let audFmt = input.audioFormat
        let scheme = HLSGenerator.scheme
        let uris = HLSGenerator.PlaylistURIs(
            video: "\(scheme)://video.m3u8",
            audio: "\(scheme)://audio.m3u8"
        )
        let codecs = "\(vidFmt.codecs),\(audFmt.codecs)"
        let width = vidFmt.width ?? 1_280
        let height = vidFmt.height ?? 720
        let audioPeak = HLSGenerator.peakBitrate(audioSegments, fallback: audFmt.bitrate)
        let mainPl = HLSGenerator.mainPlaylist(
            bandwidth: HLSGenerator.peakBitrate(videoSegments, fallback: vidFmt.bitrate)
                + audioPeak,
            codecs: codecs,
            resolution: "\(width)x\(height)",
            uris: uris
        )
        loader.register(path: "master.m3u8", content: mainPl)
        // Every form's main playlist: the probe tries them, and the proven
        // one is what the item opens.
        for form in HLSAudioVariant.Form.allCases {
            let withAudio = HLSGenerator.mainPlaylist(
                bandwidth: HLSGenerator.peakBitrate(videoSegments, fallback: vidFmt.bitrate)
                    + audioPeak,
                codecs: codecs,
                resolution: "\(width)x\(height)",
                uris: uris,
                audioOnly: form.variant(codecs: audFmt.codecs, bandwidth: audioPeak)
            )
            loader.register(path: HLSAudioVariant.probePath(form), content: withAudio)
            if form == variant {
                loader.register(path: HLSAudioVariant.entryPath, content: withAudio)
            }
        }
        let audioOnlyPl = HLSGenerator.audioOnlyMainPlaylist(
            audioCodecs: audFmt.codecs,
            audioBandwidth: audioPeak,
            audioPlaylistURI: uris.audio
        )
        loader.register(
            path: "audio-master.m3u8",
            content: audioOnlyPl
        )
    }
}
