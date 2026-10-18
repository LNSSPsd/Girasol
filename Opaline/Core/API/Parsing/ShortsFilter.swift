// SPDX-License-Identifier: CC0-1.0
import Foundation

/// Where Shorts may appear in this fork: the Subscriptions feed (a short a
/// subscribed channel posted) and a channel's own page — played in the
/// normal player like any video. Every other feed (Home, search, related)
/// drops them in the parsers. A response is parsed synchronously on one
/// thread, so the "keep them" scope is that thread's.
enum ShortsFilter {
    private static let key = "OpalineKeepsShorts"

    /// Whether the parse running on this thread keeps Shorts.
    static var keeps: Bool {
        Thread.current.threadDictionary[key] as? Bool ?? false
    }

    /// Runs `parse` with Shorts kept.
    static func keeping<T>(_ parse: () -> T) -> T {
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[key]
        dictionary[key] = true
        defer { dictionary[key] = previous }
        return parse()
    }
}
