#import "OPSleepTimer.h"

NSNotificationName const OPSleepTimerDidFireNotification = @"OPSleepTimerDidFireNotification";
NSNotificationName const OPSleepTimerDidChangeNotification = @"OPSleepTimerDidChangeNotification";

static NSTimer *OPTimer;
static NSDate *OPFireDate;
static BOOL OPEndOfSong;

@implementation OPSleepTimer

+ (BOOL)isArmed {
	return OPFireDate != nil || OPEndOfSong;
}

+ (BOOL)endOfSong {
	return OPEndOfSong;
}

+ (NSDate *)fireDate {
	return OPFireDate;
}

+ (NSArray<NSNumber *> *)minuteChoices {
	return @[ @15, @30, @45, @60, @90 ];
}

+ (void)reset {
	[OPTimer invalidate];
	OPTimer = nil;
	OPFireDate = nil;
	OPEndOfSong = NO;
}

+ (void)changed {
	[NSNotificationCenter.defaultCenter postNotificationName:OPSleepTimerDidChangeNotification object:nil];
}

+ (void)startWithMinutes:(NSInteger)minutes {
	[self reset];
	OPFireDate = [NSDate dateWithTimeIntervalSinceNow:minutes * 60];
	// A timer, not a dispatch_after: it keeps firing in the background
	// while audio plays, and it can be invalidated.
	OPTimer = [NSTimer scheduledTimerWithTimeInterval:minutes * 60
	                                          repeats:NO
	                                            block:^(NSTimer *timer) {
		                                            [self fire];
	                                            }];
	OPTimer.tolerance = 1;
	[self changed];
}

+ (void)startForEndOfSong {
	[self reset];
	OPEndOfSong = YES;
	[self changed];
}

+ (void)cancel {
	if (!self.isArmed)
		return;
	[self reset];
	[self changed];
}

+ (void)songDidEnd {
	if (OPEndOfSong)
		[self fire];
}

+ (void)fire {
	[self reset];
	[NSNotificationCenter.defaultCenter postNotificationName:OPSleepTimerDidFireNotification object:nil];
	[self changed];
}

+ (NSString *)statusText {
	if (OPEndOfSong)
		return @"Stops after this song";
	if (!OPFireDate)
		return @"Off";
	NSInteger minutes = (NSInteger)ceil(MAX(OPFireDate.timeIntervalSinceNow, 0) / 60);
	return [NSString stringWithFormat:@"Stops in %ld min", (long)minutes];
}

@end
