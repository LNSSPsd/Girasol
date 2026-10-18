// SPDX-License-Identifier: CC0-1.0
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One line of lyrics; `time` is where it starts, or -1 for unsynced lyrics.
@interface OPLyricLine : NSObject
@property (nonatomic, readonly) NSTimeInterval time;
@property (nonatomic, copy, readonly) NSString *text;
@end

/// Lyrics for a track: YouTube Music's own when they are time-synced, else
/// LRCLIB (lrclib.net), synced or plain, else YouTube Music's plain text.
@interface OPLyrics : NSObject
@property (nonatomic, copy, readonly) NSArray<OPLyricLine *> *lines;
@property (nonatomic, readonly, getter=isSynced) BOOL synced;
/// Seconds the lyrics run ahead of the song (negative: behind), set by hand
/// when a database entry is timed against a different edit. Kept per video.
@property (nonatomic) NSTimeInterval offset;
/// Which entry these came from, for the log.
@property (nonatomic, copy, readonly) NSString *source;

/// Calls back on the main queue, with nil when no lyrics were found.
/// Lyrics found once are kept on disk under `videoId`, so they show offline
/// — which is how a downloaded song gets its lyrics: fetching them at
/// download time is enough.
+ (void)fetchForVideoId:(NSString *)videoId
                  title:(NSString *)title
                 artist:(NSString *)artist
               duration:(NSTimeInterval)duration
             completion:(void (^)(OPLyrics *_Nullable lyrics))completion;

/// Parses LRC ("[01:23.45] text") into synced lines.
+ (nullable instancetype)lyricsWithLRC:(NSString *)lrc;
+ (nullable instancetype)lyricsWithPlainText:(NSString *)text;

/// The line playing at `time`, or -1 before the first one — `OPLyricsLead`
/// and `offset` early.
- (NSInteger)lineIndexAtTime:(NSTimeInterval)time;
@end

/// How much sooner than its timestamp every line lights up: the highlight
/// takes a moment to fade and scroll in, and a line lit as it is sung
/// already reads late (nearly every song needed a 0.5 s earlier nudge).
FOUNDATION_EXPORT const NSTimeInterval OPLyricsLead;

NS_ASSUME_NONNULL_END
