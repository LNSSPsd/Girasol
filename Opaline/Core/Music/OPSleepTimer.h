#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted on the main queue when the timer runs out (after its minutes, or
/// when the song it waits for ends): the music player pauses.
FOUNDATION_EXPORT NSNotificationName const OPSleepTimerDidFireNotification;
/// Posted whenever it is set, changed or turned off.
FOUNDATION_EXPORT NSNotificationName const OPSleepTimerDidChangeNotification;

/// Music mode's sleep timer: pause after a while, or at the end of the
/// playing song. Not kept across launches — a timer from last night must
/// not stop tonight's music.
@interface OPSleepTimer : NSObject
@property (class, nonatomic, readonly) BOOL isArmed;
/// Waiting for the playing song to end rather than for a time.
@property (class, nonatomic, readonly) BOOL endOfSong;
/// When it fires; nil for end of song or off.
@property (class, nonatomic, readonly, nullable) NSDate *fireDate;
/// The choices offered, in minutes.
@property (class, nonatomic, readonly) NSArray<NSNumber *> *minuteChoices;

+ (void)startWithMinutes:(NSInteger)minutes;
+ (void)startForEndOfSong;
+ (void)cancel;
/// The song ended while waiting for it: turns off and posts the fire.
+ (void)songDidEnd;
/// "Stops in 23 min", "Stops after this song", "Off".
+ (NSString *)statusText;
@end

NS_ASSUME_NONNULL_END
