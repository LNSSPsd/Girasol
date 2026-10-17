#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted on the main queue when the timer runs out (after its minutes, or
/// when the song or the album/playlist it waits for ends): the music
/// player pauses.
FOUNDATION_EXPORT NSNotificationName const OPSleepTimerDidFireNotification;
/// Posted whenever it is set, changed or turned off.
FOUNDATION_EXPORT NSNotificationName const OPSleepTimerDidChangeNotification;

/// Music mode's sleep timer: pause after a while (fading out over its last
/// minute, `fadeSeconds`), at the end of the playing song, or at the end of
/// the album or playlist. Not kept across launches — a timer from last
/// night must not stop tonight's music.
@interface OPSleepTimer : NSObject
@property (class, nonatomic, readonly) BOOL isArmed;
/// Waiting for the playing song to end rather than for a time.
@property (class, nonatomic, readonly) BOOL endOfSong;
/// Waiting for the album or playlist to end (the mix after it does not
/// start).
@property (class, nonatomic, readonly) BOOL endOfContext;
/// How long a timed stop fades out before it pauses.
@property (class, nonatomic, readonly) NSTimeInterval fadeSeconds;
/// When it fires; nil for end of song or off.
@property (class, nonatomic, readonly, nullable) NSDate *fireDate;
/// The choices offered, in minutes.
@property (class, nonatomic, readonly) NSArray<NSNumber *> *minuteChoices;

+ (void)startWithMinutes:(NSInteger)minutes;
+ (void)startForEndOfSong;
+ (void)startForEndOfContext;
+ (void)cancel;
/// The song (or the album/playlist) it waited for ended: turns off and
/// posts the fire.
+ (void)songDidEnd;
/// "Stops in 23 min", "Stops after this song", "Off".
+ (NSString *)statusText;
@end

NS_ASSUME_NONNULL_END
