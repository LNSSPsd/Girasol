import Foundation

/// The artists the user follows: YouTube's "liked artists" are the
/// subscriptions, and among those the artists are the channels YouTube Music
/// presents as an artist (with Play and Radio) — not the ones that merely
/// make videos. Each channel is asked once; verdicts are kept on the device.
enum MusicFollowedArtists {
    private static let verdictsKey = "musicFollowedArtists_verdicts"
    private static let parallel = 4

    /// Calls `update` on the main queue as artists are confirmed (sorted
    /// by name), then once more when every channel is settled.
    static func load(update: @escaping ([MusicArtistRef]) -> Void) {
        ServiceContainer.subscribedChannels.fetchSubscribedChannels { result in
            guard case .success(let channels) = result else {
                AppLog.player("followed artists: subscriptions failed")
                DispatchQueue.main.async { update([]) }
                return
            }
            classify(channels, update: update)
        }
    }

    private static func classify(
        _ channels: [SubscribedChannel],
        update: @escaping ([MusicArtistRef]) -> Void
    ) {
        var verdicts = UserDefaults.standard.dictionary(forKey: verdictsKey) as? [String: Bool] ?? [:]
        var artists: [MusicArtistRef] = channels.filter { verdicts[$0.id] == true }.map(ref)
        let unknown = channels.filter { verdicts[$0.id] == nil }
        AppLog.player(
            "followed artists: \(channels.count) subscriptions, \(artists.count) known artists,"
                + " \(unknown.count) to check"
        )
        let lock = NSLock()
        let publish = {
            lock.lock()
            let snapshot = artists
            lock.unlock()
            let sorted = snapshot.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async { update(sorted) }
        }
        publish()
        guard !unknown.isEmpty else {
            return
        }
        let limiter = DispatchSemaphore(value: parallel)
        let group = DispatchGroup()
        DispatchQueue.global(qos: .utility).async {
            for channel in unknown {
                limiter.wait()
                group.enter()
                YTMusicPublic.isArtist(channel.id) { isArtist in
                    lock.lock()
                    if let isArtist {
                        verdicts[channel.id] = isArtist
                        if isArtist {
                            artists.append(ref(channel))
                        }
                    }
                    lock.unlock()
                    if isArtist == true {
                        publish()
                    }
                    limiter.signal()
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                UserDefaults.standard.set(verdicts, forKey: verdictsKey)
                AppLog.player("followed artists: \(artists.count) artists after checking")
                publish()
            }
        }
    }

    private static func ref(_ channel: SubscribedChannel) -> MusicArtistRef {
        MusicArtistRef(browseId: channel.id, name: channel.title, subtitle: "Artist", thumbnailURL: channel.avatarURL)
    }
}
