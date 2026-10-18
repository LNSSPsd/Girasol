#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted when a setting that changes what is playing now is switched
/// (`levelVolume`, the sleep timer's end-of-song choice).
FOUNDATION_EXPORT NSNotificationName const OPMusicSettingsDidChangeNotification;
/// Posted when `diskCacheMegabytes` changes (the cache trims or empties itself).
FOUNDATION_EXPORT NSNotificationName const OPMusicDiskCacheDidChangeNotification;

/// Music mode's own settings.
@interface OPMusicSettings : NSObject
/// Load the next song before the current one ends, so a dead zone
/// (a tunnel) does not stop playback. Default YES.
@property (class, nonatomic) BOOL cacheNext;
/// How much audio to buffer ahead, for the playing song and the next one;
/// 0 means the whole song. Default 0.
@property (class, nonatomic) NSTimeInterval cacheSeconds;
/// Search while typing (after a short pause) rather than on Return.
/// Default YES.
@property (class, nonatomic) BOOL searchAsYouType;
/// After an album or playlist ends, YouTube Music's own recommendations
/// for it (with the web account) rather than a mix of what was played
/// lately. Default NO; without the web account it is the mix either way.
@property (class, nonatomic) BOOL accountRecommendations;
/// Play a song's album version where YouTube Music offers its music video
/// (see `MusicSongVersions`). Default YES.
@property (class, nonatomic) BOOL songVersions;
/// Japanese album tracks under their original title only, without the
/// romanized or translated name YouTube Music adds in English
/// ("<original> - <romaji>" → "<original>"; see `YTMusicPublic.displayTitle`). Default YES.
@property (class, nonatomic) BOOL originalTitles;
/// Songs louder than YouTube's loudness target are turned down to it, as
/// YouTube's own players do (see `PlayerLoudness`). Default YES.
@property (class, nonatomic) BOOL levelVolume;
/// Songs fade into each other over this many seconds; 0 is off (gapless).
/// Albums always play gapless. Default 0.
@property (class, nonatomic) NSTimeInterval crossfadeSeconds;
@property (class, nonatomic, readonly) NSArray<NSNumber *> *crossfadeChoices;
/// Songs played are kept on disk up to this many megabytes (`OPAudioCache`),
/// the most played kept longest; 0 is off (AVPlayer streams from
/// googlevideo, nothing is kept). Default 512.
@property (class, nonatomic) NSInteger diskCacheMegabytes;
@property (class, nonatomic, readonly) NSArray<NSNumber *> *diskCacheChoices;
+ (NSString *)titleForDiskCacheMegabytes:(NSInteger)megabytes;
/// The choices offered for `cacheSeconds`.
@property (class, nonatomic, readonly) NSArray<NSNumber *> *cacheChoices;
+ (NSString *)titleForCacheSeconds:(NSTimeInterval)seconds;
@end

NS_ASSUME_NONNULL_END
