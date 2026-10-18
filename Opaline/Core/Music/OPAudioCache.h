#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted (main queue) when a song is cached in full, or songs leave the cache.
FOUNDATION_EXPORT NSNotificationName const OPAudioCacheDidChangeNotification;

/// What a cached stream needs kept alive with its player item: the item's
/// resource loader holds its delegate weakly.
@interface OPCachedStream : NSObject
@property (nonatomic, readonly) AVPlayerItem *item;
@property (nonatomic, readonly) id<AVAssetResourceLoaderDelegate> loader;
@end

/// Music's songs on disk as they play (`OPMusicSettings.diskCacheMegabytes`).
///
/// AVPlayer plays `opcache://<id>.m4a`, a plain (not HLS) audio file whose
/// bytes this class serves through a resource loader — AVPlayer accepts a
/// custom scheme there, unlike for HLS segments. The bytes come from a
/// read-ahead of the googlevideo file in 1 MB ranges, written into
/// Application Support/AudioCache/<id>.m4a at their own offsets; AVPlayer
/// reads what it needs from that file, so what plays is what is kept.
/// A seek ahead moves the read-ahead there first. Once every byte is in,
/// the file is the itag-140 file itself and plays like a download
/// (`completeFileURL`), offline too.
///
/// A song left half-played is finished on Wi-Fi (a few MB) and dropped on
/// mobile data (`keepsDownloadingUnused`). Over the budget, the songs
/// played least lately go first: each play counts half after two weeks.
@interface OPAudioCache : NSObject
@property (class, nonatomic, copy, nullable) void (^logger)(NSString *line);
/// Whether a song nobody plays any more is still read to its end (Wi-Fi).
@property (class, nonatomic, copy, nullable) BOOL (^keepsDownloadingUnused)(void);
/// Songs a download already keeps: dropped from the cache first.
@property (class, nonatomic, copy, nullable) BOOL (^isDownloaded)(NSString *videoId);

+ (BOOL)isEnabled;
/// The whole song, when cached in full.
+ (nullable NSURL *)completeFileURLForVideoId:(NSString *)videoId;
+ (BOOL)isCompleteForVideoId:(NSString *)videoId;

/// An item that plays `url` (an audio-only mp4 of `length` bytes) while
/// keeping it. Nil when the cache is off or cannot write.
+ (nullable OPCachedStream *)streamForVideoId:(NSString *)videoId
                                          url:(NSURL *)url
                                      headers:(NSDictionary<NSString *, NSString *> *)headers
                                       length:(long long)length
                                         itag:(NSInteger)itag;

/// A play of the song, for what stays when the cache is full.
+ (void)notePlayOfVideoId:(NSString *)videoId;

/// Complete songs and bytes on disk (partial files included). Main queue.
+ (void)measure:(void (^)(NSUInteger complete, unsigned long long bytes))completion;
+ (void)clear;
/// Down to the budget (all of it when off).
+ (void)trim;
@end

NS_ASSUME_NONNULL_END
