import SystemConfiguration

/// Wi-Fi against cellular, the only distinction the quality preference needs
/// (#108). `NWPathMonitor` exists on iOS 12 too, but it answers through a
/// callback and has to be kept running; these flags answer synchronously at
/// the moment a stream is picked, which is the only moment that asks.
enum NetworkType {
    static var isCellular: Bool {
        guard let flags else {
            return false
        }
        return flags.contains(.isWWAN) && flags.contains(.reachable)
    }

    /// No route at all (airplane mode, no Wi-Fi and no cellular). A Wi-Fi
    /// without internet still counts as online: streams fail there instead.
    static var isOffline: Bool {
        guard let flags else {
            return false
        }
        return !flags.contains(.reachable) || flags.contains(.connectionRequired)
    }

    private static var flags: SCNetworkReachabilityFlags? {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        let reachability = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                SCNetworkReachabilityCreateWithAddress(nil, $0)
            }
        }
        guard let reachability else {
            return nil
        }
        var flags = SCNetworkReachabilityFlags()
        guard SCNetworkReachabilityGetFlags(reachability, &flags) else {
            return nil
        }
        return flags
    }
}
