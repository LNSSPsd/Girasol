#import "OPLyrics.h"

static NSString *const OPLyricsHost = @"https://lrclib.net";
/// LRCLIB asks clients to identify themselves.
static NSString *const OPLyricsUserAgent = @"Opaline (https://github.com/verback2308/Opaline)";

@interface OPLyricLine ()
- (instancetype)initWithTime:(NSTimeInterval)time text:(NSString *)text;
@end

@implementation OPLyricLine
- (instancetype)initWithTime:(NSTimeInterval)time text:(NSString *)text {
	if ((self = [super init])) {
		_time = time;
		_text = [text copy];
	}
	return self;
}
@end

@interface OPLyrics ()
@property (nonatomic, copy) NSString *videoId;
@property (nonatomic, copy, readwrite) NSString *source;
- (instancetype)initWithLines:(NSArray<OPLyricLine *> *)lines synced:(BOOL)synced;
@end

const NSTimeInterval OPLyricsLead = 0.5;

static NSString *OPOffsetKey(NSString *videoId) {
	return [@"lyricsOffset." stringByAppendingString:videoId];
}

/// Offsets set before `OPLyricsLead` existed already include it: once,
/// they give it back, so those songs keep the timing they were tuned to.
static void OPMigrateOffsetsForLead(void) {
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
		NSString *doneKey = @"lyricsOffset.leadMigrated";
		if ([defaults boolForKey:doneKey])
			return;
		for (NSString *key in defaults.dictionaryRepresentation.allKeys) {
			if ([key hasPrefix:@"lyricsOffset."] && ![key isEqualToString:doneKey])
				[defaults setDouble:[defaults doubleForKey:key] - OPLyricsLead forKey:key];
		}
		[defaults setBool:YES forKey:doneKey];
	});
}

@implementation OPLyrics

- (instancetype)initWithLines:(NSArray<OPLyricLine *> *)lines synced:(BOOL)synced {
	if ((self = [super init])) {
		_lines = [lines copy];
		_synced = synced;
		_source = @"";
	}
	return self;
}

#pragma mark - Parsing

+ (instancetype)lyricsWithLRC:(NSString *)lrc {
	static NSRegularExpression *stamp;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		stamp = [NSRegularExpression regularExpressionWithPattern:@"\\[(\\d+):(\\d+(?:\\.\\d+)?)\\]"
		                                                  options:0
		                                                    error:NULL];
	});
	NSMutableArray<OPLyricLine *> *lines = [NSMutableArray array];
	for (NSString *raw in [lrc componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
		NSArray<NSTextCheckingResult *> *matches =
		    [stamp matchesInString:raw options:0 range:NSMakeRange(0, raw.length)];
		if (matches.count == 0)
			continue;
		// A line may carry several stamps when it repeats ("[00:10][01:30] la").
		NSUInteger textStart = NSMaxRange(matches.lastObject.range);
		NSString *text = [[raw substringFromIndex:textStart]
		    stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
		for (NSTextCheckingResult *match in matches) {
			double minutes = [[raw substringWithRange:[match rangeAtIndex:1]] doubleValue];
			double seconds = [[raw substringWithRange:[match rangeAtIndex:2]] doubleValue];
			[lines addObject:[[OPLyricLine alloc] initWithTime:minutes * 60 + seconds text:text]];
		}
	}
	if (lines.count == 0)
		return nil;
	// Every line at one time is no timing at all (it would sit on the last).
	BOOL timed = lines.count == 1;
	for (OPLyricLine *line in lines)
		timed = timed || line.time != lines.firstObject.time;
	if (!timed)
		return nil;
	[lines sortUsingComparator:^NSComparisonResult(OPLyricLine *a, OPLyricLine *b) {
		return a.time < b.time ? NSOrderedAscending : (a.time > b.time ? NSOrderedDescending : NSOrderedSame);
	}];
	return [[self alloc] initWithLines:lines synced:YES];
}

+ (instancetype)lyricsWithPlainText:(NSString *)text {
	NSMutableArray<OPLyricLine *> *lines = [NSMutableArray array];
	for (NSString *raw in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
		[lines addObject:[[OPLyricLine alloc]
		                     initWithTime:-1
		                             text:[raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]]];
	}
	BOOL anyText = NO;
	for (OPLyricLine *line in lines)
		anyText = anyText || line.text.length > 0;
	return anyText ? [[self alloc] initWithLines:lines synced:NO] : nil;
}

- (void)setOffset:(NSTimeInterval)offset {
	_offset = offset;
	if (self.videoId)
		[NSUserDefaults.standardUserDefaults setDouble:offset forKey:OPOffsetKey(self.videoId)];
}

- (NSInteger)lineIndexAtTime:(NSTimeInterval)time {
	if (!self.synced)
		return -1;
	time += self.offset + OPLyricsLead;
	NSInteger found = -1;
	for (NSInteger i = 0; i < (NSInteger)self.lines.count; i++) {
		if (self.lines[i].time > time)
			break;
		found = i;
	}
	return found;
}

#pragma mark - Lookup

/// "Song (Official Video) [MV]" → "Song": decorations that never appear in
/// a database title.
static NSString *OPCleanTitle(NSString *title) {
	static NSRegularExpression *decoration;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		decoration = [NSRegularExpression
		    regularExpressionWithPattern:@"\\s*[\\(\\[【「][^\\)\\]】」]*(official|video|audio|lyric|mv|m/v|music|visualizer|hd|4k)[^\\)\\]】」]*[\\)\\]】」]"
		                         options:NSRegularExpressionCaseInsensitive
		                           error:NULL];
	});
	NSString *clean = [decoration stringByReplacingMatchesInString:title
	                                                       options:0
	                                                         range:NSMakeRange(0, title.length)
	                                                  withTemplate:@""];
	return [clean stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
}

static NSURLRequest *OPRequest(NSString *path, NSDictionary<NSString *, NSString *> *query) {
	NSURLComponents *components = [NSURLComponents componentsWithString:[OPLyricsHost stringByAppendingString:path]];
	NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray array];
	for (NSString *key in query)
		[items addObject:[NSURLQueryItem queryItemWithName:key value:query[key]]];
	components.queryItems = items;
	NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:components.URL];
	[request setValue:OPLyricsUserAgent forHTTPHeaderField:@"User-Agent"];
	request.timeoutInterval = 10;
	return request;
}

static OPLyrics *OPLyricsFromRecord(NSDictionary *record) {
	if (![record isKindOfClass:NSDictionary.class])
		return nil;
	NSString *synced = record[@"syncedLyrics"];
	if ([synced isKindOfClass:NSString.class] && synced.length > 0) {
		OPLyrics *lyrics = [OPLyrics lyricsWithLRC:synced];
		if (lyrics)
			return lyrics;
	}
	NSString *plain = record[@"plainLyrics"];
	if ([plain isKindOfClass:NSString.class] && plain.length > 0)
		return [OPLyrics lyricsWithPlainText:plain];
	return nil;
}

static void OPFetchJSON(NSURLRequest *request, void (^done)(id _Nullable json)) {
	[[NSURLSession.sharedSession dataTaskWithRequest:request
	                               completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
		                               NSInteger status = [(NSHTTPURLResponse *)response statusCode];
		                               id json = (data && !error && status == 200)
		                                             ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]
		                                             : nil;
		                               done(json);
	                               }] resume];
}

/// A number from JSON, which may be missing, `null` or a string.
static double OPNumber(id value) {
	if ([value isKindOfClass:NSNumber.class] || [value isKindOfClass:NSString.class])
		return [value doubleValue];
	return 0;
}

#pragma mark - Cache

static NSURL *OPCacheFile(NSString *videoId) {
	NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
	                                                       inDomains:NSUserDomainMask].firstObject;
	NSURL *dir = [support URLByAppendingPathComponent:@"Lyrics" isDirectory:YES];
	[NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:NULL];
	return [dir URLByAppendingPathComponent:[videoId stringByAppendingPathExtension:@"json"]];
}

static NSString *OPDescribe(NSDictionary *record) {
	if (![record isKindOfClass:NSDictionary.class])
		return @"cache";
	if ([record[@"source"] isKindOfClass:NSString.class])
		return record[@"source"];
	if (!record[@"id"])
		return @"cache";
	return [NSString stringWithFormat:@"lrclib #%@ \"%@\" by %@, %.0fs",
	                                  record[@"id"], record[@"trackName"], record[@"artistName"],
	                                  OPNumber(record[@"duration"])];
}

/// Attaches what the player needs to know about where these came from.
static OPLyrics *OPAttach(OPLyrics *lyrics, NSString *videoId, NSDictionary *record) {
	lyrics.videoId = videoId;
	lyrics.source = OPDescribe(record);
	OPMigrateOffsetsForLead();
	lyrics->_offset = [NSUserDefaults.standardUserDefaults doubleForKey:OPOffsetKey(videoId)];
	return lyrics;
}

/// Bumped when the lookup finds more: plain lyrics stored by an older
/// one get another try at synced ones.
static NSInteger const OPLookupVersion = 2;

/// Keeps only the lyric fields of a record, where they came from, and
/// which lookup found them.
static void OPStoreRecord(NSString *videoId, NSDictionary *record) {
	NSMutableDictionary *kept = [NSMutableDictionary dictionary];
	for (NSString *key in @[ @"syncedLyrics", @"plainLyrics", @"source" ]) {
		if ([record[key] isKindOfClass:NSString.class])
			kept[key] = record[key];
	}
	kept[@"lookup"] = @(OPLookupVersion);
	NSData *data = [NSJSONSerialization dataWithJSONObject:kept options:0 error:NULL];
	[data writeToURL:OPCacheFile(videoId) atomically:YES];
}

#pragma mark - Matching

/// Brackets and quotes of every kind as spaces: uploaders wrap the song
/// name however they like ("Artist『Song』MV", "Artist - 「Song」"), and the
/// databases' searches match words, not punctuation.
static NSString *OPSearchText(NSString *text) {
	static NSRegularExpression *marks;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		marks = [NSRegularExpression regularExpressionWithPattern:@"[\\(\\)\\[\\]{}【】「」『』〈〉《》〔〕（）\"“”‘’]+|\\s{2,}"
		                                                  options:0
		                                                    error:NULL];
	});
	NSString *spaced = [marks stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:@" "];
	return [spaced stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
}

/// The entry's title appears in the video's, whatever surrounds it there.
static BOOL OPTitleContains(NSString *videoTitle, NSString *name) {
	NSString *bare = OPSearchText(name);
	return bare.length > 0 &&
	       [videoTitle rangeOfString:bare options:NSCaseInsensitiveSearch | NSWidthInsensitiveSearch].location != NSNotFound;
}

/// How well a database entry fits the video, lower is better, -1 to reject.
/// Length alone proves nothing (another band's song of the same title runs
/// 4:08 against a fan upload's 4:09): the entry's title must appear in the
/// video's title, and one of its artists in that title or the channel name,
/// whoever uploaded it. Then length: within 5 s is the same recording; an
/// MV runs longer than its song (intro, outro, a skit), so a song up to a
/// minute shorter still counts, ranked behind close lengths — its lyrics run
/// early by the intro, which the nudge fixes. No match beats a wrong one.
static double OPMatchScore(NSString *name, NSArray<NSString *> *entryArtists, double length,
                           NSTimeInterval duration, NSString *videoTitle, NSString *channel) {
	// "Song (feat. A & B)": the featured singers are rarely in the video's
	// title, and they are artists, not part of the song's name.
	static NSRegularExpression *featuring;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		featuring = [NSRegularExpression
		    regularExpressionWithPattern:@"\\s*[\\(\\[（](feat\\.?|ft\\.|featuring)\\s[^\\)\\]）]*[\\)\\]）]|\\s+(feat\\.?|ft\\.|featuring)\\s.*$"
		                         options:NSRegularExpressionCaseInsensitive
		                           error:NULL];
	});
	name = [featuring stringByReplacingMatchesInString:name options:0 range:NSMakeRange(0, name.length) withTemplate:@""];
	NSString *video = OPSearchText([NSString stringWithFormat:@"%@ %@", channel, videoTitle]);
	BOOL byArtist = NO;
	for (NSString *entryArtist in entryArtists)
		byArtist = byArtist || OPTitleContains(video, entryArtist);
	if (!OPTitleContains(OPSearchText(videoTitle), name) || !byArtist)
		return -1;
	if (duration <= 0)
		return 0;
	double gap = fabs(length - duration);
	if (gap <= 5)
		return gap;
	if (length > 0 && length < duration && duration - length <= 60)
		return 6 + gap / 60;
	return -1;
}

/// "A, B & C feat. D" → each name, for `OPMatchScore`.
static NSArray<NSString *> *OPArtistNames(NSString *credit) {
	static NSRegularExpression *separators;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		separators = [NSRegularExpression
		    regularExpressionWithPattern:@"\\s*(,|&|、|×|\\bx\\b|\\band\\b|\\bfeat\\.?|\\bft\\.?|\\bwith\\b)\\s*"
		                         options:NSRegularExpressionCaseInsensitive
		                           error:NULL];
	});
	NSString *split = [separators stringByReplacingMatchesInString:credit options:0 range:NSMakeRange(0, credit.length) withTemplate:@"\n"];
	NSMutableArray<NSString *> *names = [NSMutableArray array];
	for (NSString *part in [split componentsSeparatedByString:@"\n"]) {
		NSString *name = [part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
		if (name.length > 0)
			[names addObject:name];
	}
	return names;
}

#pragma mark - YouTube Music

/// Asks YouTube Music signed out: no cookies kept or sent.
static NSURLSession *OPMusicSession(void) {
	static NSURLSession *session;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
		config.HTTPShouldSetCookies = NO;
		config.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyNever;
		config.timeoutIntervalForRequest = 10;
		session = [NSURLSession sessionWithConfiguration:config];
	});
	return session;
}

/// The website client finds a song's lyrics page; only the Android app's
/// client gets it back with timing.
static void OPMusicPost(NSString *endpoint, BOOL android, NSString *hl, NSDictionary *body,
                        void (^done)(id _Nullable json)) {
	NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://music.youtube.com/youtubei/v1/%@?prettyPrint=false", endpoint]];
	NSMutableDictionary *full = [body mutableCopy];
	full[@"context"] = @{
		@"client" : android ? @{@"clientName" : @"ANDROID_MUSIC", @"clientVersion" : @"7.21.50", @"hl" : hl}
		                    : @{@"clientName" : @"WEB_REMIX", @"clientVersion" : @"1.20260304.03.00", @"hl" : hl}
	};
	NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
	request.HTTPMethod = @"POST";
	request.HTTPBody = [NSJSONSerialization dataWithJSONObject:full options:0 error:NULL];
	[request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
	[request setValue:android ? @"21" : @"67" forHTTPHeaderField:@"X-YouTube-Client-Name"];
	if (!android)
		[request setValue:@"https://music.youtube.com" forHTTPHeaderField:@"Origin"];
	[[OPMusicSession() dataTaskWithRequest:request
	                     completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
		                     NSInteger status = [(NSHTTPURLResponse *)response statusCode];
		                     done(data && !error && status == 200
		                              ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]
		                              : nil);
	                     }] resume];
}

/// Every value under `key`, depth first, in document order.
static void OPCollect(id node, NSString *key, NSMutableArray *found) {
	if ([node isKindOfClass:NSDictionary.class]) {
		for (NSString *name in node) {
			if ([name isEqualToString:key])
				[found addObject:node[name]];
			OPCollect(node[name], key, found);
		}
	} else if ([node isKindOfClass:NSArray.class]) {
		for (id child in node)
			OPCollect(child, key, found);
	}
}

static id OPFirst(id node, NSString *key) {
	NSMutableArray *found = [NSMutableArray array];
	OPCollect(node, key, found);
	return found.firstObject;
}

static NSString *OPRunsText(id text) {
	NSMutableString *joined = [NSMutableString string];
	for (NSDictionary *run in [text isKindOfClass:NSDictionary.class] ? text[@"runs"] : nil) {
		if ([run isKindOfClass:NSDictionary.class] && [run[@"text"] isKindOfClass:NSString.class])
			[joined appendString:run[@"text"]];
	}
	return joined;
}

/// Kana or kanji: a Japanese (or Chinese) title.
static BOOL OPHasJapanese(NSString *text) {
	return [text rangeOfString:@"[\\p{Hiragana}\\p{Katakana}\\p{Han}]" options:NSRegularExpressionSearch].location !=
	       NSNotFound;
}

/// The song's title and artist as YouTube Music names them in `next`'s queue.
static NSArray<NSString *> *OPQueueNames(id next, NSString *videoId) {
	NSMutableArray *panels = [NSMutableArray array];
	OPCollect(next, @"playlistPanelVideoRenderer", panels);
	for (NSDictionary *panel in panels) {
		if (![panel isKindOfClass:NSDictionary.class] || ![panel[@"videoId"] isEqual:videoId])
			continue;
		NSString *title = OPRunsText(panel[@"title"]);
		// "Artist • Album • Year" or "Channel • views • likes".
		NSString *artist = [OPRunsText(panel[@"longBylineText"]) componentsSeparatedByString:@" • "].firstObject;
		if (title.length > 0 && artist.length > 0)
			return @[ title, artist ];
	}
	return nil;
}

/// YouTube Music's lyrics for a song (Musixmatch, LyricFind): a record like
/// LRCLIB's, `syncedLyrics` as LRC when they are timed. Nil without any.
/// Asked in Japanese for a Japanese title, `names` is the song's title and
/// artist as they are in Japanese: in English YouTube Music romanizes them
/// (a romaji name for a kanji one), which no lyrics database lists.
static void OPFetchYouTubeMusic(NSString *videoId, BOOL japanese,
                                void (^done)(NSDictionary *_Nullable record, NSArray<NSString *> *_Nullable names)) {
	OPMusicPost(@"next", NO, japanese ? @"ja" : @"en", @{@"videoId" : videoId, @"isAudioOnly" : @YES}, ^(id next) {
		NSArray<NSString *> *names = japanese ? OPQueueNames(next, videoId) : nil;
		// The song's own Lyrics tab; the queue's other songs name theirs too.
		NSMutableArray *tabs = [NSMutableArray array];
		OPCollect(next, @"tabRenderer", tabs);
		NSString *browseId = nil;
		for (NSDictionary *tab in tabs) {
			id candidate = OPFirst(tab[@"endpoint"], @"browseId");
			if ([candidate isKindOfClass:NSString.class] && [candidate hasPrefix:@"MPLYt"]) {
				browseId = candidate;
				break;
			}
		}
		if (!browseId) {
			done(nil, names);
			return;
		}
		OPMusicPost(@"browse", YES, @"en", @{@"browseId" : browseId}, ^(id page) {
			id source = OPFirst(page, @"sourceMessage");
			NSString *credit = [NSString stringWithFormat:@"YouTube Music (%@)",
			                                              [source isKindOfClass:NSString.class] ? source : @"?"];
			NSArray *timed = OPFirst(page, @"timedLyricsData");
			if ([timed isKindOfClass:NSArray.class] && timed.count > 0) {
				// Some songs come as lines without any timing (no cueRange):
				// those are plain lyrics.
				NSMutableString *lrc = [NSMutableString string];
				NSMutableArray<NSString *> *texts = [NSMutableArray array];
				BOOL anyTime = NO;
				for (NSDictionary *line in timed) {
					if (![line isKindOfClass:NSDictionary.class])
						continue;
					id start = OPFirst(line, @"startTimeMilliseconds");
					anyTime = anyTime || OPNumber(start) > 0;
					double seconds = OPNumber(start) / 1000;
					NSString *text = [line[@"lyricLine"] isKindOfClass:NSString.class] ? line[@"lyricLine"] : @"";
					[texts addObject:text];
					[lrc appendFormat:@"[%02d:%05.2f]%@\n", (int)(seconds / 60), fmod(seconds, 60), text];
				}
				done(anyTime ? @{@"syncedLyrics" : lrc, @"source" : credit}
				             : @{@"plainLyrics" : [texts componentsJoinedByString:@"\n"], @"source" : credit},
				     names);
				return;
			}
			NSDictionary *shelf = OPFirst(page, @"musicDescriptionShelfRenderer");
			NSString *plain = [shelf isKindOfClass:NSDictionary.class] ? OPRunsText(shelf[@"description"]) : @"";
			if (!source && [shelf isKindOfClass:NSDictionary.class])
				credit = [NSString stringWithFormat:@"YouTube Music (%@)", OPRunsText(shelf[@"footer"])];
			done(plain.length > 0 ? @{@"plainLyrics" : plain, @"source" : credit} : nil, names);
		});
	});
}

#pragma mark - LRCLIB

/// What to search for: "Artist Song", or the title alone when it names
/// the artist itself ("Artist - Song"). On a miss, its first part alone:
/// a cover's "Song / Original artist - Covered by …" is found under the
/// song's name, and the match still needs that artist.
static NSArray<NSString *> *OPQueries(NSString *track, NSString *artist) {
	NSString *first = OPSearchText([track containsString:@" - "] ? track : [NSString stringWithFormat:@"%@ %@", artist, track]);
	NSString *lead = [track componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/／|｜"]]
	                     .firstObject;
	lead = OPSearchText([lead componentsSeparatedByString:@" - "].firstObject);
	return lead.length > 0 && ![lead isEqualToString:first] && ![first hasSuffix:lead] ? @[ first, lead ] : @[ first ];
}

/// `title` and `artist` are what to look up; `videoTitle` and `channel`
/// what an entry must match (both names of the song, when there are two).
static void OPFetchLRCLIB(NSString *title, NSString *artist, NSString *videoTitle, NSString *channel,
                          NSTimeInterval duration, void (^done)(NSDictionary *_Nullable record)) {
	NSString *track = OPCleanTitle(title);
	// Exact match first: artist, title and length (LRCLIB allows ±2 s).
	NSMutableDictionary *exact = [@{@"track_name" : track, @"artist_name" : artist} mutableCopy];
	if (duration > 0)
		exact[@"duration"] = [NSString stringWithFormat:@"%.0f", duration];
	OPFetchJSON(OPRequest(@"/api/get", exact), ^(id json) {
		if (OPLyricsFromRecord(json)) {
			done(json);
			return;
		}
		// YouTube titles often carry the artist ("Artist - Song"), and channel
		// names are not always the artist: a free-text search over both, then
		// the closest length with synced lyrics wins.
		NSArray<NSString *> *queries = OPQueries(track, artist);
		__block void (^search)(NSUInteger);
		search = ^(NSUInteger index) {
			if (index >= queries.count) {
				search = nil;
				done(nil);
				return;
			}
			OPFetchJSON(OPRequest(@"/api/search", @{@"q" : queries[index]}), ^(id results) {
				NSDictionary *best = nil;
				double bestScore = DBL_MAX;
				for (NSDictionary *record in [results isKindOfClass:NSArray.class] ? results : nil) {
					if (![record isKindOfClass:NSDictionary.class])
						continue;
					NSString *name = [record[@"trackName"] isKindOfClass:NSString.class] ? record[@"trackName"] : @"";
					NSString *by = [record[@"artistName"] isKindOfClass:NSString.class] ? record[@"artistName"] : @"";
					double score = OPMatchScore(name, OPArtistNames(by), OPNumber(record[@"duration"]), duration,
					                            videoTitle, channel);
					if (score < 0)
						continue;
					if (![record[@"syncedLyrics"] isKindOfClass:NSString.class])
						score += 10;
					if (score < bestScore) {
						bestScore = score;
						best = record;
					}
				}
				if (best) {
					search = nil;
					done(best);
				} else {
					search(index + 1);
				}
			});
		};
		search(0);
	});
}

#pragma mark - NetEase Cloud Music

/// NetEase's line credits ("作词 : …") are not lyrics, and neither is a
/// translation someone typed in.
static NSString *OPStripCredits(NSString *lrc) {
	static NSRegularExpression *credit;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		credit = [NSRegularExpression
		    regularExpressionWithPattern:@"^(\\[[\\d:.]+\\])+\\s*(作词|作詞|作曲|编曲|編曲|制作人|词|曲)\\s*[:：].*$\\n?"
		                         options:NSRegularExpressionAnchorsMatchLines
		                           error:NULL];
	});
	NSString *stripped = [credit stringByReplacingMatchesInString:lrc
	                                                      options:0
	                                                        range:NSMakeRange(0, lrc.length)
	                                                 withTemplate:@""];
	// A translation typed into the lyrics shares its line's timestamp:
	// only the first line of each time is kept.
	NSMutableSet<NSString *> *seen = [NSMutableSet set];
	NSMutableArray<NSString *> *kept = [NSMutableArray array];
	for (NSString *line in [stripped componentsSeparatedByString:@"\n"]) {
		NSRange end = [line rangeOfString:@"]"];
		NSString *stamp = [line hasPrefix:@"["] && end.location != NSNotFound ? [line substringToIndex:end.location] : nil;
		if (stamp && [seen containsObject:stamp])
			continue;
		if (stamp)
			[seen addObject:stamp];
		[kept addObject:line];
	}
	return [kept componentsJoinedByString:@"\n"];
}

/// The search result that fits the video best, or nil.
static NSDictionary *OPNetEaseBest(id json, NSString *track, NSTimeInterval duration, NSString *videoTitle,
                                   NSString *channel) {
	NSArray *songs = [json isKindOfClass:NSDictionary.class] ? OPFirst(json, @"songs") : nil;
	NSDictionary *best = nil;
	double bestScore = DBL_MAX;
	for (NSDictionary *song in [songs isKindOfClass:NSArray.class] ? songs : nil) {
		if (![song isKindOfClass:NSDictionary.class] || ![song[@"name"] isKindOfClass:NSString.class])
			continue;
		NSString *name = song[@"name"];
		// Karaoke and other versions share the title and the length.
		NSRegularExpression *version = [NSRegularExpression
		    regularExpressionWithPattern:@"instrumental|off vocal|karaoke|カラオケ|伴奏|acoustic|remix|cover"
		                         options:NSRegularExpressionCaseInsensitive
		                           error:NULL];
		BOOL otherVersion = [version firstMatchInString:name options:0 range:NSMakeRange(0, name.length)] &&
		                    ![version firstMatchInString:track options:0 range:NSMakeRange(0, track.length)];
		NSMutableArray<NSString *> *names = [NSMutableArray array];
		for (NSDictionary *by in [song[@"artists"] isKindOfClass:NSArray.class] ? song[@"artists"] : nil) {
			if ([by isKindOfClass:NSDictionary.class] && [by[@"name"] isKindOfClass:NSString.class])
				[names addObject:by[@"name"]];
		}
		double score = OPMatchScore(name, names, OPNumber(song[@"duration"]) / 1000, duration, videoTitle, channel);
		if (otherVersion || score < 0)
			continue;
		if (score < bestScore) {
			bestScore = score;
			best = song;
		}
	}
	return best;
}

/// A synced record of the song's original lines, or nil.
static void OPFetchNetEaseLyrics(NSDictionary *best, void (^done)(NSDictionary *_Nullable record)) {
	NSString *lyricURL = [NSString stringWithFormat:@"https://music.163.com/api/song/lyric?id=%@&lv=1", best[@"id"]];
	NSMutableURLRequest *lyricRequest = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:lyricURL]];
	lyricRequest.timeoutInterval = 10;
	OPFetchJSON(lyricRequest, ^(id lyric) {
		id lrc = [lyric isKindOfClass:NSDictionary.class] ? OPFirst(lyric[@"lrc"], @"lyric") : nil;
		NSString *synced = [lrc isKindOfClass:NSString.class] ? OPStripCredits(lrc) : @"";
		NSString *source = [NSString stringWithFormat:@"NetEase #%@ \"%@\", %.0fs", best[@"id"], best[@"name"],
		                                              OPNumber(best[@"duration"]) / 1000];
		done([OPLyrics lyricsWithLRC:synced] ? @{@"syncedLyrics" : synced, @"source" : source} : nil);
	});
}

/// NetEase Cloud Music: the widest catalog of synced Japanese (and Chinese)
/// lyrics. Only the original lines — its translations are a separate field
/// that is not asked for. Only a synced record, matched by length.
static void OPFetchNetEase(NSString *title, NSString *artist, NSString *videoTitle, NSString *channel,
                           NSTimeInterval duration, void (^done)(NSDictionary *_Nullable record)) {
	NSString *track = OPCleanTitle(title);
	NSArray<NSString *> *queries = OPQueries(track, artist);
	__block void (^lookup)(NSUInteger);
	lookup = ^(NSUInteger index) {
		if (index >= queries.count) {
			lookup = nil;
			done(nil);
			return;
		}
		NSURLComponents *search = [NSURLComponents componentsWithString:@"https://music.163.com/api/search/get"];
		search.queryItems = @[
			[NSURLQueryItem queryItemWithName:@"s" value:queries[index]],
			[NSURLQueryItem queryItemWithName:@"type" value:@"1"], [NSURLQueryItem queryItemWithName:@"limit" value:@"10"]
		];
		NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:search.URL];
		request.timeoutInterval = 10;
		OPFetchJSON(request, ^(id json) {
			NSDictionary *best = OPNetEaseBest(json, track, duration, videoTitle, channel);
			if (best) {
				lookup = nil;
				OPFetchNetEaseLyrics(best, done);
			} else {
				lookup(index + 1);
			}
		});
	};
	lookup(0);
}

#pragma mark - Lookup order

/// The first synced lyrics of: YouTube Music (they belong to this very
/// track), LRCLIB, NetEase. Else plain ones: LRCLIB's, YouTube Music's.
/// Plain lyrics cached by an older lookup get one more try at a synced
/// version.
+ (void)fetchForVideoId:(NSString *)videoId
                  title:(NSString *)title
                 artist:(NSString *)artist
               duration:(NSTimeInterval)duration
             completion:(void (^)(OPLyrics *))completion {
	NSData *cachedData = [NSData dataWithContentsOfURL:OPCacheFile(videoId)];
	NSDictionary *cached = cachedData ? [NSJSONSerialization JSONObjectWithData:cachedData options:0 error:NULL] : nil;
	OPLyrics *fromCache = OPLyricsFromRecord(cached);
	if (fromCache && (fromCache.synced || OPNumber(cached[@"lookup"]) >= OPLookupVersion)) {
		completion(OPAttach(fromCache, videoId, cached));
		return;
	}
	void (^finish)(NSDictionary *) = ^(NSDictionary *record) {
		OPLyrics *lyrics = OPLyricsFromRecord(record);
		if (lyrics) {
			OPStoreRecord(videoId, record);
			OPAttach(lyrics, videoId, record);
		}
		dispatch_async(dispatch_get_main_queue(), ^{
			completion(lyrics);
		});
	};
	OPFetchYouTubeMusic(videoId, OPHasJapanese(title), ^(NSDictionary *ytmusic, NSArray<NSString *> *names) {
		if (ytmusic[@"syncedLyrics"]) {
			finish(ytmusic);
			return;
		}
		// The databases list Japanese songs under their Japanese names; an
		// entry may match either name.
		NSString *queryTitle = names ? names[0] : title;
		NSString *queryArtist = names ? names[1] : artist;
		NSString *matchTitle = names ? [NSString stringWithFormat:@"%@ %@", names[0], title] : title;
		NSString *matchChannel = names ? [NSString stringWithFormat:@"%@ %@", names[1], artist] : artist;
		void (^orPlain)(NSDictionary *) = ^(NSDictionary *plain) {
			OPFetchNetEase(queryTitle, queryArtist, matchTitle, matchChannel, duration, ^(NSDictionary *netease) {
				finish(netease ?: plain);
			});
		};
		OPFetchLRCLIB(queryTitle, queryArtist, matchTitle, matchChannel, duration, ^(NSDictionary *lrclib) {
			OPLyrics *found = OPLyricsFromRecord(lrclib);
			if (found.synced)
				finish(lrclib);
			else
				orPlain(found ? lrclib : (ytmusic ?: (fromCache ? cached : nil)));
		});
	});
}

@end
