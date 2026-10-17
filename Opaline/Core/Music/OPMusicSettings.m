#import "OPMusicSettings.h"

static NSString *const OPCacheNextKey = @"music_cacheNext";
static NSString *const OPCacheSecondsKey = @"music_cacheSeconds";
static NSString *const OPSearchAsYouTypeKey = @"music_searchAsYouType";
static NSString *const OPAccountRecommendationsKey = @"music_accountRecommendations";
static NSString *const OPSongVersionsKey = @"music_songVersions";
static NSString *const OPOriginalTitlesKey = @"music_originalTitles";

@implementation OPMusicSettings

+ (BOOL)cacheNext {
	NSNumber *stored = [NSUserDefaults.standardUserDefaults objectForKey:OPCacheNextKey];
	return stored ? stored.boolValue : YES;
}

+ (void)setCacheNext:(BOOL)cacheNext {
	[NSUserDefaults.standardUserDefaults setBool:cacheNext forKey:OPCacheNextKey];
}

+ (NSTimeInterval)cacheSeconds {
	return [NSUserDefaults.standardUserDefaults doubleForKey:OPCacheSecondsKey];
}

+ (void)setCacheSeconds:(NSTimeInterval)cacheSeconds {
	[NSUserDefaults.standardUserDefaults setDouble:cacheSeconds forKey:OPCacheSecondsKey];
}

+ (BOOL)searchAsYouType {
	NSNumber *stored = [NSUserDefaults.standardUserDefaults objectForKey:OPSearchAsYouTypeKey];
	return stored ? stored.boolValue : YES;
}

+ (void)setSearchAsYouType:(BOOL)searchAsYouType {
	[NSUserDefaults.standardUserDefaults setBool:searchAsYouType forKey:OPSearchAsYouTypeKey];
}

+ (BOOL)accountRecommendations {
	return [NSUserDefaults.standardUserDefaults boolForKey:OPAccountRecommendationsKey];
}

+ (void)setAccountRecommendations:(BOOL)accountRecommendations {
	[NSUserDefaults.standardUserDefaults setBool:accountRecommendations forKey:OPAccountRecommendationsKey];
}

+ (BOOL)songVersions {
	NSNumber *stored = [NSUserDefaults.standardUserDefaults objectForKey:OPSongVersionsKey];
	return stored ? stored.boolValue : YES;
}

+ (void)setSongVersions:(BOOL)songVersions {
	[NSUserDefaults.standardUserDefaults setBool:songVersions forKey:OPSongVersionsKey];
}

+ (BOOL)originalTitles {
	NSNumber *stored = [NSUserDefaults.standardUserDefaults objectForKey:OPOriginalTitlesKey];
	return stored ? stored.boolValue : YES;
}

+ (void)setOriginalTitles:(BOOL)originalTitles {
	[NSUserDefaults.standardUserDefaults setBool:originalTitles forKey:OPOriginalTitlesKey];
}

+ (NSArray<NSNumber *> *)cacheChoices {
	return @[ @30, @60, @180, @0 ];
}

+ (NSString *)titleForCacheSeconds:(NSTimeInterval)seconds {
	if (seconds <= 0)
		return @"Whole song";
	if (seconds < 60)
		return [NSString stringWithFormat:@"%.0f seconds", seconds];
	return seconds == 60 ? @"1 minute" : [NSString stringWithFormat:@"%.0f minutes", seconds / 60];
}

@end
