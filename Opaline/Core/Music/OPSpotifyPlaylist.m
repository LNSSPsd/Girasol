#import "OPSpotifyPlaylist.h"

/// The embed page is served to browsers; this iOS version's Safari is what
/// it gets.
static NSString *const OPSpotifyUserAgent =
    @"Mozilla/5.0 (iPhone; CPU iPhone OS 14_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) "
    @"Version/14.0.2 Mobile/15E148 Safari/604.1";
/// Spotify's web player's persisted query for a playlist page.
static NSString *const OPSpotifyPlaylistHash = @"19ff1327c29e99c208c86d7a9d8f1929cfdf3d3202a0ff4253c821f1901aa94d";
static NSInteger const OPSpotifyPageSize = 100;
/// 10,000 tracks: Spotify's own playlist limit.
static NSInteger const OPSpotifyMaxPages = 100;

@interface OPSpotifyTrack ()
- (instancetype)initWithId:(NSString *)trackId
                     title:(NSString *)title
                   artists:(NSArray<NSString *> *)artists
                     album:(nullable NSString *)album
                  duration:(NSTimeInterval)duration;
@end

@implementation OPSpotifyTrack
- (instancetype)initWithId:(NSString *)trackId
                     title:(NSString *)title
                   artists:(NSArray<NSString *> *)artists
                     album:(NSString *)album
                  duration:(NSTimeInterval)duration {
	if ((self = [super init])) {
		_trackId = [trackId copy];
		_title = [title copy];
		_artists = [artists copy];
		_album = [album copy];
		_duration = duration;
	}
	return self;
}
@end

@interface OPSpotifyPlaylist ()
@property (nonatomic, copy, readwrite) NSString *playlistId;
@property (nonatomic, copy, readwrite) NSString *name;
@property (nonatomic, copy, readwrite) NSString *owner;
@property (nonatomic, copy, readwrite, nullable) NSString *coverURL;
@property (nonatomic, copy, readwrite) NSArray<OPSpotifyTrack *> *tracks;
@property (nonatomic, readwrite) NSInteger total;
@property (nonatomic, copy, readwrite) NSString *source;
@end

static id OPDig(id node, NSArray<NSString *> *path) {
	for (NSString *key in path) {
		if (![node isKindOfClass:NSDictionary.class])
			return nil;
		node = node[key];
	}
	return node;
}

static NSString *OPString(id value) {
	return [value isKindOfClass:NSString.class] ? value : nil;
}

static double OPNumber(id value) {
	if ([value isKindOfClass:NSNumber.class] || [value isKindOfClass:NSString.class])
		return [value doubleValue];
	return 0;
}

/// `spotify:track:<id>` → `<id>`.
static NSString *OPTrackId(NSString *uri) {
	return [uri hasPrefix:@"spotify:track:"] ? [uri substringFromIndex:@"spotify:track:".length] : nil;
}

/// "A, B" — the embed writes every artist into one line.
static NSArray<NSString *> *OPSplitArtists(NSString *line) {
	NSMutableArray<NSString *> *names = [NSMutableArray array];
	for (NSString *part in [line componentsSeparatedByString:@","]) {
		NSString *name = [part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
		if (name.length > 0)
			[names addObject:name];
	}
	return names;
}

/// The page's `__NEXT_DATA__` JSON.
static NSDictionary *OPNextData(NSData *data) {
	NSString *html = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
	NSString *open = @"<script id=\"__NEXT_DATA__\" type=\"application/json\">";
	NSRange start = html ? [html rangeOfString:open] : NSMakeRange(NSNotFound, 0);
	if (start.location == NSNotFound)
		return nil;
	NSUInteger from = NSMaxRange(start);
	NSRange end = [html rangeOfString:@"</script>" options:0 range:NSMakeRange(from, html.length - from)];
	if (end.location == NSNotFound)
		return nil;
	NSData *json = [[html substringWithRange:NSMakeRange(from, end.location - from)] dataUsingEncoding:NSUTF8StringEncoding];
	id parsed = [NSJSONSerialization JSONObjectWithData:json options:0 error:NULL];
	return [parsed isKindOfClass:NSDictionary.class] ? parsed : nil;
}

static NSArray<OPSpotifyTrack *> *OPEmbedTracks(NSArray *list) {
	NSMutableArray<OPSpotifyTrack *> *tracks = [NSMutableArray array];
	for (NSDictionary *item in [list isKindOfClass:NSArray.class] ? list : @[]) {
		if (![item isKindOfClass:NSDictionary.class])
			continue;
		NSString *trackId = OPTrackId(OPString(item[@"uri"]));
		NSString *title = OPString(item[@"title"]);
		// Podcast episodes and local files have no track id.
		if (!trackId || title.length == 0)
			continue;
		[tracks addObject:[[OPSpotifyTrack alloc] initWithId:trackId
		                                               title:title
		                                             artists:OPSplitArtists(OPString(item[@"subtitle"]) ?: @"")
		                                               album:nil
		                                            duration:OPNumber(item[@"duration"]) / 1000]];
	}
	return tracks;
}

static NSArray<OPSpotifyTrack *> *OPPathfinderTracks(NSArray *items) {
	NSMutableArray<OPSpotifyTrack *> *tracks = [NSMutableArray array];
	for (NSDictionary *item in [items isKindOfClass:NSArray.class] ? items : @[]) {
		NSDictionary *data = OPDig(item, @[ @"itemV2", @"data" ]);
		if (![data isKindOfClass:NSDictionary.class] || ![data[@"__typename"] isEqual:@"Track"])
			continue;
		NSString *trackId = OPTrackId(OPString(data[@"uri"]));
		NSString *title = OPString(data[@"name"]);
		if (!trackId || title.length == 0)
			continue;
		NSMutableArray<NSString *> *artists = [NSMutableArray array];
		NSArray *credits = OPDig(data, @[ @"artists", @"items" ]);
		for (NSDictionary *artist in [credits isKindOfClass:NSArray.class] ? credits : @[]) {
			NSString *name = OPString(OPDig(artist, @[ @"profile", @"name" ]));
			if (name.length > 0)
				[artists addObject:name];
		}
		[tracks addObject:[[OPSpotifyTrack alloc] initWithId:trackId
		                                               title:title
		                                             artists:artists
		                                               album:OPString(OPDig(data, @[ @"albumOfTrack", @"name" ]))
		                                            duration:OPNumber(OPDig(data, @[ @"trackDuration", @"totalMilliseconds" ])) / 1000]];
	}
	return tracks;
}

static NSString *OPJSONText(id object) {
	NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL];
	return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"{}";
}

@implementation OPSpotifyPlaylist

+ (void)fetchPlaylistId:(NSString *)playlistId completion:(void (^)(OPSpotifyPlaylist *))completion {
	void (^finish)(OPSpotifyPlaylist *) = ^(OPSpotifyPlaylist *playlist) {
		dispatch_async(dispatch_get_main_queue(), ^{
			completion(playlist);
		});
	};
	NSURL *url = [NSURL URLWithString:[@"https://open.spotify.com/embed/playlist/" stringByAppendingString:playlistId]];
	NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
	[request setValue:OPSpotifyUserAgent forHTTPHeaderField:@"User-Agent"];
	[[NSURLSession.sharedSession dataTaskWithRequest:request
	                               completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
		                               NSInteger status = [(NSHTTPURLResponse *)response statusCode];
		                               NSDictionary *next = (data && !error && status == 200) ? OPNextData(data) : nil;
		                               NSDictionary *state = OPDig(next, @[ @"props", @"pageProps", @"state" ]);
		                               NSDictionary *entity = OPDig(state, @[ @"data", @"entity" ]);
		                               if (![entity isKindOfClass:NSDictionary.class] || !OPString(entity[@"name"])) {
			                               finish(nil);
			                               return;
		                               }
		                               OPSpotifyPlaylist *playlist = [OPSpotifyPlaylist new];
		                               playlist.playlistId = playlistId;
		                               playlist.name = OPString(entity[@"name"]);
		                               playlist.owner = OPString(entity[@"subtitle"]) ?: @"";
		                               NSArray *sources = OPDig(entity, @[ @"coverArt", @"sources" ]);
		                               if ([sources isKindOfClass:NSArray.class] && sources.count > 0)
			                               playlist.coverURL = OPString(OPDig(sources.firstObject, @[ @"url" ]));
		                               playlist.tracks = OPEmbedTracks(entity[@"trackList"]);
		                               playlist.total = playlist.tracks.count < OPSpotifyPageSize ? (NSInteger)playlist.tracks.count : -1;
		                               playlist.source = @"embed";
		                               NSString *token = OPString(OPDig(state, @[ @"settings", @"session", @"accessToken" ]));
		                               if (!token) {
			                               playlist.source = @"embed only: no token";
			                               finish(playlist);
			                               return;
		                               }
		                               [self pagesOf:playlist token:token offset:0 found:@[] completion:^{
			                               finish(playlist);
		                               }];
	                               }] resume];
}

/// Every page through the web player's query; the embed's tracks stay
/// when a page is refused and it got no further than they do. `offset`
/// counts every item read, episodes and local files too.
+ (void)pagesOf:(OPSpotifyPlaylist *)playlist
          token:(NSString *)token
         offset:(NSUInteger)offset
          found:(NSArray<OPSpotifyTrack *> *)found
     completion:(void (^)(void))completion {
	NSDictionary *variables = @{
		@"uri" : [@"spotify:playlist:" stringByAppendingString:playlist.playlistId],
		@"offset" : @(offset),
		@"limit" : @(OPSpotifyPageSize)
	};
	NSDictionary *extensions = @{ @"persistedQuery" : @{ @"version" : @1, @"sha256Hash" : OPSpotifyPlaylistHash } };
	NSURLComponents *components = [NSURLComponents componentsWithString:@"https://api-partner.spotify.com/pathfinder/v1/query"];
	components.queryItems = @[
		[NSURLQueryItem queryItemWithName:@"operationName" value:@"fetchPlaylist"],
		[NSURLQueryItem queryItemWithName:@"variables" value:OPJSONText(variables)],
		[NSURLQueryItem queryItemWithName:@"extensions" value:OPJSONText(extensions)]
	];
	NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:components.URL];
	[request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
	[request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
	[[NSURLSession.sharedSession dataTaskWithRequest:request
	                               completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
		                               NSInteger status = [(NSHTTPURLResponse *)response statusCode];
		                               id json = (data && !error && status == 200)
		                                             ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]
		                                             : nil;
		                               NSDictionary *content = OPDig(json, @[ @"data", @"playlistV2", @"content" ]);
		                               if (![content isKindOfClass:NSDictionary.class]) {
			                               if (found.count > playlist.tracks.count)
				                               playlist.tracks = found;
			                               playlist.source = [NSString stringWithFormat:@"embed + pathfinder %lu, then refused status=%ld",
			                                                                            (unsigned long)found.count, (long)status];
			                               completion();
			                               return;
		                               }
		                               NSArray *items = content[@"items"];
		                               NSArray<OPSpotifyTrack *> *all = [found arrayByAddingObjectsFromArray:OPPathfinderTracks(items)];
		                               NSInteger total = (NSInteger)OPNumber(content[@"totalCount"]);
		                               NSUInteger read = offset + ([items isKindOfClass:NSArray.class] ? items.count : 0);
		                               BOOL more = [items isKindOfClass:NSArray.class] && items.count > 0 && (NSInteger)read < total;
		                               if (more && read / OPSpotifyPageSize < OPSpotifyMaxPages) {
			                               [self pagesOf:playlist token:token offset:read found:all completion:completion];
			                               return;
		                               }
		                               playlist.tracks = all;
		                               playlist.total = total;
		                               playlist.source = [NSString stringWithFormat:@"pathfinder %lu of %ld", (unsigned long)all.count, (long)total];
		                               completion();
	                               }] resume];
}

@end
