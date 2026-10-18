// SPDX-License-Identifier: CC0-1.0
#import "OPAudioCache.h"
#import "OPMusicSettings.h"

NSNotificationName const OPAudioCacheDidChangeNotification = @"OPAudioCacheDidChangeNotification";

static NSString *const OPCacheScheme = @"opcache";
/// The first range after a start or a seek is small, so sound comes soon;
/// the rest come a megabyte at a time.
static long long const OPFirstChunk = 256 * 1024;
static long long const OPChunk = 1024 * 1024;
static NSUInteger const OPRespondLimit = 512 * 1024;
/// A play counts half after this long (what stays when the cache is full).
static NSTimeInterval const OPHalfLife = 14 * 24 * 3600;

static void (^sLogger)(NSString *);
static BOOL (^sKeepsDownloadingUnused)(void);
static BOOL (^sIsDownloaded)(NSString *);

static void OPLog(NSString *line) {
	void (^logger)(NSString *) = sLogger;
	if (logger)
		logger([@"audio cache: " stringByAppendingString:line]);
}

/// Everything here runs on this one queue: the resource loaders' callbacks,
/// the read-ahead's responses, the files. No locks beyond `sComplete`'s.
static dispatch_queue_t OPQueue(void) {
	static dispatch_queue_t queue;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		queue = dispatch_queue_create("com.opaline.audio-cache", DISPATCH_QUEUE_SERIAL);
	});
	return queue;
}

static NSURL *OPDirectory(void) {
	static NSURL *directory;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		NSURL *base = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
		                                                   inDomains:NSUserDomainMask].firstObject;
		directory = [base URLByAppendingPathComponent:@"AudioCache" isDirectory:YES];
		[NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:NULL];
		[directory setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:NULL];
	});
	return directory;
}

static NSURL *OPAudioFile(NSString *videoId) {
	return [OPDirectory() URLByAppendingPathComponent:[videoId stringByAppendingPathExtension:@"m4a"]];
}

static NSURL *OPMetaFile(NSString *videoId) {
	return [OPDirectory() URLByAppendingPathComponent:[videoId stringByAppendingPathExtension:@"json"]];
}

static NSMutableDictionary *OPReadMeta(NSString *videoId) {
	NSData *data = [NSData dataWithContentsOfURL:OPMetaFile(videoId)];
	id meta = data ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:NULL] : nil;
	return [meta isKindOfClass:NSMutableDictionary.class] ? meta : [NSMutableDictionary dictionary];
}

static void OPWriteMeta(NSString *videoId, NSDictionary *meta) {
	NSData *data = [NSJSONSerialization dataWithJSONObject:meta options:0 error:NULL];
	[data writeToURL:OPMetaFile(videoId) atomically:YES];
}

#pragma mark - Complete songs

/// Ids cached in full, read from disk once; asked from lists on the main
/// thread, so not behind the queue.
static NSMutableSet<NSString *> *sComplete;

static NSMutableSet<NSString *> *OPCompleteSet(void) {
	@synchronized(OPCacheScheme) {
		if (!sComplete) {
			sComplete = [NSMutableSet set];
			for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:OPDirectory().path error:NULL]) {
				if (![name.pathExtension isEqualToString:@"json"])
					continue;
				NSString *videoId = name.stringByDeletingPathExtension;
				if ([OPReadMeta(videoId)[@"complete"] boolValue] &&
				    [NSFileManager.defaultManager fileExistsAtPath:OPAudioFile(videoId).path])
					[sComplete addObject:videoId];
			}
		}
		return sComplete;
	}
}

static void OPSetComplete(NSString *videoId, BOOL complete) {
	@synchronized(OPCacheScheme) {
		if (complete)
			[OPCompleteSet() addObject:videoId];
		else
			[OPCompleteSet() removeObject:videoId];
	}
}

#pragma mark - The header's lengths

/// YouTube's adaptive MP4 states the whole length in its header (`mvhd`,
/// `tkhd`, `mdhd`) although every sample is in the fragments after it, and
/// AVFoundation adds the two: a 174.33 s song reads as 348.67 s (measured on
/// the itag-140 files; the downloads' `file claims` log line). A
/// fragmented file's header should say 0 — patched in place, same size, so
/// no byte moves.
static void OPZeroHeaderDurations(uint8_t *bytes, NSUInteger length, NSUInteger offset, NSUInteger end, int depth) {
	while (offset + 8 <= end && end <= length) {
		uint32_t size = CFSwapInt32BigToHost(*(uint32_t *)(bytes + offset));
		if (size < 8 || offset + size > end)
			return;
		const char *type = (const char *)(bytes + offset + 4);
		uint8_t *body = bytes + offset + 8;
		NSUInteger bodyLength = size - 8;
		if (strncmp(type, "moov", 4) == 0 || strncmp(type, "trak", 4) == 0 || strncmp(type, "mdia", 4) == 0) {
			if (depth < 4)
				OPZeroHeaderDurations(bytes, length, offset + 8, offset + size, depth + 1);
		} else if (strncmp(type, "mvhd", 4) == 0 || strncmp(type, "mdhd", 4) == 0) {
			// version 0: 4-byte times, scale, 4-byte duration; version 1: 8-byte.
			if (body[0] == 0 && bodyLength >= 20)
				memset(body + 16, 0, 4);
			else if (body[0] == 1 && bodyLength >= 32)
				memset(body + 24, 0, 8);
		} else if (strncmp(type, "tkhd", 4) == 0) {
			if (body[0] == 0 && bodyLength >= 24)
				memset(body + 20, 0, 4);
			else if (body[0] == 1 && bodyLength >= 36)
				memset(body + 28, 0, 8);
		}
		offset += size;
	}
}

#pragma mark - One song

@interface OPCacheEntry : NSObject
@property (nonatomic, copy) NSString *videoId;
@property (nonatomic, copy) NSURL *url;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *headers;
@property (nonatomic) long long length;
@property (nonatomic) NSInteger itag;
@property (nonatomic, strong) NSFileHandle *file;
@property (nonatomic, strong) NSMutableIndexSet *ranges;
@property (nonatomic, strong) NSMutableArray<AVAssetResourceLoadingRequest *> *pending;
@property (nonatomic) NSInteger users;
@property (nonatomic, strong, nullable) NSURLSessionDataTask *task;
@property (nonatomic) long long taskStart;
@property (nonatomic) long long taskEnd;
@property (nonatomic) NSInteger failures;
@property (nonatomic) BOOL complete;
@property (nonatomic) BOOL failed;
/// Where AVPlayer last asked for bytes the file does not have yet.
@property (nonatomic) long long wanted;
@end

static NSMutableDictionary<NSString *, OPCacheEntry *> *sEntries;

static NSURLSession *OPSession(void) {
	static NSURLSession *session;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
		config.HTTPShouldSetCookies = NO;
		config.URLCache = nil;
		NSOperationQueue *delegateQueue = [NSOperationQueue new];
		delegateQueue.underlyingQueue = OPQueue();
		delegateQueue.maxConcurrentOperationCount = 1;
		session = [NSURLSession sessionWithConfiguration:config delegate:nil delegateQueue:delegateQueue];
	});
	return session;
}

@implementation OPCacheEntry

/// A new or resumed song: a partial file of the same stream is continued,
/// any other is started over. On the queue.
- (instancetype)initWithVideoId:(NSString *)videoId length:(long long)length itag:(NSInteger)itag {
	if ((self = [super init])) {
		_videoId = [videoId copy];
		_length = length;
		_itag = itag;
		_pending = [NSMutableArray array];
		_ranges = [NSMutableIndexSet indexSet];
		_wanted = -1;
		NSMutableDictionary *meta = OPReadMeta(videoId);
		BOOL same = [meta[@"length"] longLongValue] == length && [meta[@"itag"] integerValue] == itag &&
		            [NSFileManager.defaultManager fileExistsAtPath:OPAudioFile(videoId).path];
		if (same) {
			for (NSArray<NSNumber *> *range in meta[@"ranges"] ?: @[])
				if (range.count == 2)
					[_ranges addIndexesInRange:NSMakeRange(range[0].unsignedIntegerValue, range[1].unsignedIntegerValue)];
		} else {
			[NSFileManager.defaultManager removeItemAtURL:OPAudioFile(videoId) error:NULL];
		}
		if (![NSFileManager.defaultManager fileExistsAtPath:OPAudioFile(videoId).path])
			[NSFileManager.defaultManager createFileAtPath:OPAudioFile(videoId).path contents:nil attributes:nil];
		_file = [NSFileHandle fileHandleForUpdatingURL:OPAudioFile(videoId) error:NULL];
		if (!_file)
			return nil;
		_complete = [_ranges containsIndexesInRange:NSMakeRange(0, (NSUInteger)length)];
		[self saveMeta];
	}
	return self;
}

- (void)saveMeta {
	NSMutableDictionary *meta = OPReadMeta(self.videoId);
	NSMutableArray *ranges = [NSMutableArray array];
	[self.ranges enumerateRangesUsingBlock:^(NSRange range, BOOL *stop) {
		[ranges addObject:@[ @(range.location), @(range.length) ]];
	}];
	meta[@"length"] = @(self.length);
	meta[@"itag"] = @(self.itag);
	meta[@"ranges"] = ranges;
	meta[@"complete"] = @(self.complete);
	meta[@"touched"] = @(NSDate.date.timeIntervalSince1970);
	OPWriteMeta(self.videoId, meta);
}

/// The end of the run of saved bytes `offset` is in, or `offset` itself.
- (long long)savedEndFrom:(long long)offset {
	__block long long end = offset;
	[self.ranges enumerateRangesUsingBlock:^(NSRange range, BOOL *stop) {
		if ((long long)range.location <= offset && offset < (long long)NSMaxRange(range)) {
			end = (long long)NSMaxRange(range);
			*stop = YES;
		}
	}];
	return end;
}

/// The first byte not saved at or after `offset`, -1 for none.
- (long long)missingFrom:(long long)offset {
	long long at = MAX(0, offset);
	while (at < self.length) {
		long long end = [self savedEndFrom:at];
		if (end == at)
			return at;
		at = end;
	}
	return -1;
}

- (void)addRequest:(AVAssetResourceLoadingRequest *)request {
	AVAssetResourceLoadingContentInformationRequest *info = request.contentInformationRequest;
	if (info) {
		info.contentType = AVFileTypeMPEG4;
		info.contentLength = self.length;
		info.byteRangeAccessSupported = YES;
	}
	if (!request.dataRequest) {
		[request finishLoading];
		return;
	}
	[self.pending addObject:request];
	[self serve];
	[self pump];
}

- (void)cancelRequest:(AVAssetResourceLoadingRequest *)request {
	[self.pending removeObject:request];
}

/// Hands AVPlayer whatever it asked for that the file has.
- (void)serve {
	long long wanted = -1;
	for (AVAssetResourceLoadingRequest *request in self.pending.copy) {
		if (request.isCancelled || request.isFinished) {
			[self.pending removeObject:request];
			continue;
		}
		AVAssetResourceLoadingDataRequest *data = request.dataRequest;
		long long offset = data.currentOffset;
		long long end = data.requestsAllDataToEndOfResource ? self.length : data.requestedOffset + data.requestedLength;
		end = MIN(end, self.length);
		while (offset < end) {
			long long saved = MIN([self savedEndFrom:offset], end);
			if (saved <= offset)
				break;
			NSUInteger count = (NSUInteger)MIN(saved - offset, (long long)OPRespondLimit);
			[self.file seekToFileOffset:(unsigned long long)offset];
			NSData *bytes = [self.file readDataOfLength:count];
			if (bytes.length == 0)
				break;
			[data respondWithData:bytes];
			offset += (long long)bytes.length;
		}
		if (offset >= end) {
			[request finishLoading];
			[self.pending removeObject:request];
		} else if (wanted < 0 || offset < wanted) {
			wanted = offset;
		}
	}
	self.wanted = wanted;
}

/// Keeps one range in flight: where AVPlayer waits first, else the next
/// gap from the start — while someone plays the song, or on Wi-Fi.
- (void)pump {
	if (self.complete || self.failed)
		return;
	if (self.task) {
		// A seek far from the running range: that range can wait.
		if (self.wanted >= 0 && (self.wanted < self.taskStart || self.wanted >= self.taskEnd)) {
			[self.task cancel];
			self.task = nil;
		} else {
			return;
		}
	}
	BOOL needed = self.wanted >= 0;
	if (!needed && self.users == 0 && !(sKeepsDownloadingUnused && sKeepsDownloadingUnused()))
		return;
	long long start = [self missingFrom:needed ? self.wanted : 0];
	if (start < 0 && needed)
		start = [self missingFrom:0];
	if (start < 0) {
		[self finishIfComplete];
		return;
	}
	long long chunk = needed && ![self.ranges containsIndex:(NSUInteger)MAX(0, start - 1)] ? OPFirstChunk : OPChunk;
	long long end = MIN(start + chunk, self.length);
	// Up to the next saved byte only.
	for (long long at = start; at < end; at += 4096) {
		if ([self.ranges containsIndex:(NSUInteger)at]) {
			end = at;
			break;
		}
	}
	end = MAX(end, start + 1);
	NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:self.url];
	[self.headers enumerateKeysAndObjectsUsingBlock:^(NSString *field, NSString *value, BOOL *stop) {
		[request setValue:value forHTTPHeaderField:field];
	}];
	[request setValue:[NSString stringWithFormat:@"bytes=%lld-%lld", start, end - 1] forHTTPHeaderField:@"Range"];
	__weak OPCacheEntry *weakSelf = self;
	__block NSURLSessionDataTask *task;
	task = [OPSession() dataTaskWithRequest:request
	                      completionHandler:^(NSData *body, NSURLResponse *response, NSError *error) {
		                      [weakSelf received:body response:response error:error task:task start:start end:end];
	                      }];
	self.task = task;
	self.taskStart = start;
	self.taskEnd = end;
	[task resume];
}

- (void)received:(NSData *)body
        response:(NSURLResponse *)response
           error:(NSError *)error
            task:(NSURLSessionDataTask *)task
           start:(long long)start
             end:(long long)end {
	if (task != self.task)
		return; // replaced by a seek
	self.task = nil;
	NSInteger status = [(NSHTTPURLResponse *)response statusCode];
	if (error || (status != 206 && status != 200) || body.length == 0) {
		self.failures += 1;
		OPLog([NSString stringWithFormat:@"%@ bytes %lld-%lld failed: status %ld %@", self.videoId, start, end - 1,
		                                 (long)status, error.localizedDescription ?: @""]);
		// An expired or refused URL stays refused; the player's own retry
		// brings a new one (`streamForVideoId:` updates `url`).
		if (status == 403 || status == 410 || self.failures >= 3) {
			self.failed = YES;
			NSError *failure = error ?: [NSError errorWithDomain:@"OPAudioCache" code:status userInfo:nil];
			for (AVAssetResourceLoadingRequest *request in self.pending)
				[request finishLoadingWithError:failure];
			[self.pending removeAllObjects];
			return;
		}
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)NSEC_PER_SEC), OPQueue(), ^{
			[self pump];
		});
		return;
	}
	self.failures = 0;
	// A 200 is the whole file whatever was asked; keep the part asked for.
	long long from = status == 200 ? 0 : start;
	NSData *bytes = body;
	if (from == 0 && bytes.length >= 8) {
		NSMutableData *patched = [bytes mutableCopy];
		OPZeroHeaderDurations(patched.mutableBytes, patched.length, 0, MIN(patched.length, (NSUInteger)64 * 1024), 0);
		bytes = patched;
	}
	long long count = MIN((long long)bytes.length, self.length - from);
	[self.file seekToFileOffset:(unsigned long long)from];
	[self.file writeData:[bytes subdataWithRange:NSMakeRange(0, (NSUInteger)count)]];
	[self.ranges addIndexesInRange:NSMakeRange((NSUInteger)from, (NSUInteger)count)];
	[self saveMeta];
	[self serve];
	[self finishIfComplete];
	[self pump];
}

- (void)finishIfComplete {
	if (self.complete || ![self.ranges containsIndexesInRange:NSMakeRange(0, (NSUInteger)self.length)])
		return;
	self.complete = YES;
	[self.file synchronizeFile];
	[self saveMeta];
	OPSetComplete(self.videoId, YES);
	OPLog([NSString stringWithFormat:@"%@ complete (%.1f MB)", self.videoId, self.length / 1048576.0]);
	dispatch_async(dispatch_get_main_queue(), ^{
		[NSNotificationCenter.defaultCenter postNotificationName:OPAudioCacheDidChangeNotification object:nil];
	});
	[OPAudioCache trim];
}

/// The last player of the song is gone: on mobile data the read-ahead
/// stops (and the partial file waits for another play), on Wi-Fi it
/// finishes the song.
- (void)letGo {
	self.users -= 1;
	if (self.users > 0)
		return;
	for (AVAssetResourceLoadingRequest *request in self.pending)
		if (!request.isFinished && !request.isCancelled)
			[request finishLoadingWithError:[NSError errorWithDomain:@"OPAudioCache" code:-1 userInfo:nil]];
	[self.pending removeAllObjects];
	self.wanted = -1;
	if (!self.complete && !self.failed && sKeepsDownloadingUnused && sKeepsDownloadingUnused()) {
		[self pump];
		return;
	}
	[self.task cancel];
	self.task = nil;
	[self saveMeta];
	if (sEntries[self.videoId] == self)
		[sEntries removeObjectForKey:self.videoId];
}

@end

#pragma mark - Loader

@interface OPCacheLoader : NSObject <AVAssetResourceLoaderDelegate>
@property (nonatomic, strong) OPCacheEntry *entry;
@end

@implementation OPCacheLoader

- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader
    shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)loadingRequest {
	if (![loadingRequest.request.URL.scheme isEqualToString:OPCacheScheme])
		return NO;
	[self.entry addRequest:loadingRequest];
	return YES;
}

- (void)resourceLoader:(AVAssetResourceLoader *)resourceLoader
    didCancelLoadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest {
	[self.entry cancelRequest:loadingRequest];
}

- (void)dealloc {
	OPCacheEntry *entry = _entry;
	dispatch_async(OPQueue(), ^{
		[entry letGo];
	});
}

@end

@implementation OPCachedStream
- (instancetype)initWithItem:(AVPlayerItem *)item loader:(id<AVAssetResourceLoaderDelegate>)loader {
	if ((self = [super init])) {
		_item = item;
		_loader = loader;
	}
	return self;
}
@end

#pragma mark - The cache

@implementation OPAudioCache

+ (void (^)(NSString *))logger {
	return sLogger;
}

+ (void)setLogger:(void (^)(NSString *))logger {
	sLogger = [logger copy];
}

+ (BOOL (^)(void))keepsDownloadingUnused {
	return sKeepsDownloadingUnused;
}

+ (void)setKeepsDownloadingUnused:(BOOL (^)(void))block {
	sKeepsDownloadingUnused = [block copy];
}

+ (BOOL (^)(NSString *))isDownloaded {
	return sIsDownloaded;
}

+ (void)setIsDownloaded:(BOOL (^)(NSString *))block {
	sIsDownloaded = [block copy];
}

+ (BOOL)isEnabled {
	return OPMusicSettings.diskCacheMegabytes > 0;
}

+ (BOOL)isCompleteForVideoId:(NSString *)videoId {
	if (!self.isEnabled)
		return NO;
	@synchronized(OPCacheScheme) {
		return [OPCompleteSet() containsObject:videoId];
	}
}

+ (NSURL *)completeFileURLForVideoId:(NSString *)videoId {
	return [self isCompleteForVideoId:videoId] ? OPAudioFile(videoId) : nil;
}

+ (OPCachedStream *)streamForVideoId:(NSString *)videoId
                                 url:(NSURL *)url
                             headers:(NSDictionary<NSString *, NSString *> *)headers
                              length:(long long)length
                                itag:(NSInteger)itag {
	if (!self.isEnabled || length <= 0)
		return nil;
	__block OPCacheEntry *entry;
	dispatch_sync(OPQueue(), ^{
		if (!sEntries)
			sEntries = [NSMutableDictionary dictionary];
		entry = sEntries[videoId];
		if (entry && (entry.length != length || entry.itag != itag)) {
			[entry.task cancel];
			entry = nil;
		}
		if (!entry) {
			entry = [[OPCacheEntry alloc] initWithVideoId:videoId length:length itag:itag];
			if (entry)
				sEntries[videoId] = entry;
		}
		// A fresh URL each time: the last one may have expired.
		entry.url = url;
		entry.headers = headers;
		entry.failed = NO;
		entry.failures = 0;
		entry.users += 1;
	});
	if (!entry) {
		OPLog([NSString stringWithFormat:@"%@: cannot write the file", videoId]);
		return nil;
	}
	OPCacheLoader *loader = [OPCacheLoader new];
	loader.entry = entry;
	NSURL *assetURL = [NSURL URLWithString:[NSString stringWithFormat:@"%@://%@.m4a", OPCacheScheme, videoId]];
	AVURLAsset *asset = [AVURLAsset URLAssetWithURL:assetURL options:nil];
	[asset.resourceLoader setDelegate:loader queue:OPQueue()];
	OPLog([NSString stringWithFormat:@"%@: streaming through the cache (%.1f MB, %.0f%% saved)", videoId,
	                                 length / 1048576.0, 100.0 * entry.ranges.count / length]);
	return [[OPCachedStream alloc] initWithItem:[AVPlayerItem playerItemWithAsset:asset] loader:loader];
}

+ (void)notePlayOfVideoId:(NSString *)videoId {
	if (!self.isEnabled)
		return;
	dispatch_async(OPQueue(), ^{
		NSMutableDictionary *meta = OPReadMeta(videoId);
		NSMutableArray *plays = [meta[@"plays"] mutableCopy] ?: [NSMutableArray array];
		[plays addObject:@(NSDate.date.timeIntervalSince1970)];
		while (plays.count > 30)
			[plays removeObjectAtIndex:0];
		meta[@"plays"] = plays;
		meta[@"touched"] = @(NSDate.date.timeIntervalSince1970);
		OPWriteMeta(videoId, meta);
	});
}

/// Recent plays count most: each one halves over `OPHalfLife`.
static double OPScore(NSDictionary *meta, NSTimeInterval now) {
	double score = 0;
	for (NSNumber *play in meta[@"plays"] ?: @[])
		score += pow(0.5, (now - play.doubleValue) / OPHalfLife);
	return score;
}

static unsigned long long OPFileSize(NSURL *url) {
	NSNumber *size;
	[url getResourceValue:&size forKey:NSURLFileSizeKey error:NULL];
	return size.unsignedLongLongValue;
}

+ (void)trim {
	dispatch_async(OPQueue(), ^{
		unsigned long long budget = (unsigned long long)MAX(0, OPMusicSettings.diskCacheMegabytes) * 1048576ULL;
		NSTimeInterval now = NSDate.date.timeIntervalSince1970;
		NSMutableArray<NSDictionary *> *songs = [NSMutableArray array];
		unsigned long long total = 0;
		for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:OPDirectory().path error:NULL]) {
			if (![name.pathExtension isEqualToString:@"json"])
				continue;
			NSString *videoId = name.stringByDeletingPathExtension;
			NSDictionary *meta = OPReadMeta(videoId);
			unsigned long long size = OPFileSize(OPAudioFile(videoId));
			total += size;
			BOOL inUse = sEntries[videoId] != nil;
			// A download keeps it anyway; a partial file nobody came back
			// to in three days will not be finished.
			BOOL redundant = sIsDownloaded && sIsDownloaded(videoId);
			BOOL stale = ![meta[@"complete"] boolValue] && now - [meta[@"touched"] doubleValue] > 3 * 24 * 3600;
			if (inUse && !redundant)
				continue;
			[songs addObject:@{
				@"id" : videoId,
				@"size" : @(size),
				@"score" : @(redundant || stale || budget == 0 ? -1 : OPScore(meta, now)),
				@"touched" : meta[@"touched"] ?: @0,
			}];
		}
		[songs sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
			NSComparisonResult byScore = [a[@"score"] compare:b[@"score"]];
			return byScore != NSOrderedSame ? byScore : [a[@"touched"] compare:b[@"touched"]];
		}];
		NSUInteger removed = 0;
		for (NSDictionary *song in songs) {
			if (total <= budget && [song[@"score"] doubleValue] >= 0)
				break;
			NSString *videoId = song[@"id"];
			if (sEntries[videoId])
				continue; // playing now
			[NSFileManager.defaultManager removeItemAtURL:OPAudioFile(videoId) error:NULL];
			// The play counts stay with a song that is only gone for space.
			NSMutableDictionary *meta = OPReadMeta(videoId);
			[meta removeObjectsForKeys:@[ @"ranges", @"complete", @"length", @"itag" ]];
			if ([song[@"score"] doubleValue] < 0 || [meta[@"plays"] count] == 0)
				[NSFileManager.defaultManager removeItemAtURL:OPMetaFile(videoId) error:NULL];
			else
				OPWriteMeta(videoId, meta);
			OPSetComplete(videoId, NO);
			total -= MIN(total, [song[@"size"] unsignedLongLongValue]);
			removed += 1;
		}
		if (removed > 0) {
			OPLog([NSString stringWithFormat:@"removed %lu songs, %.0f MB of %.0f MB used", (unsigned long)removed,
			                                 total / 1048576.0, budget / 1048576.0]);
			dispatch_async(dispatch_get_main_queue(), ^{
				[NSNotificationCenter.defaultCenter postNotificationName:OPAudioCacheDidChangeNotification object:nil];
			});
		}
	});
}

+ (void)clear {
	dispatch_async(OPQueue(), ^{
		for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:OPDirectory().path error:NULL]) {
			NSString *videoId = name.stringByDeletingPathExtension;
			if (sEntries[videoId])
				continue;
			[NSFileManager.defaultManager removeItemAtURL:[OPDirectory() URLByAppendingPathComponent:name] error:NULL];
			OPSetComplete(videoId, NO);
		}
		OPLog(@"cleared");
		dispatch_async(dispatch_get_main_queue(), ^{
			[NSNotificationCenter.defaultCenter postNotificationName:OPAudioCacheDidChangeNotification object:nil];
		});
	});
}

+ (void)measure:(void (^)(NSUInteger, unsigned long long))completion {
	dispatch_async(OPQueue(), ^{
		unsigned long long bytes = 0;
		for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:OPDirectory().path error:NULL])
			if ([name.pathExtension isEqualToString:@"m4a"])
				bytes += OPFileSize([OPDirectory() URLByAppendingPathComponent:name]);
		NSUInteger complete;
		@synchronized(OPCacheScheme) {
			complete = OPCompleteSet().count;
		}
		dispatch_async(dispatch_get_main_queue(), ^{
			completion(complete, bytes);
		});
	});
}

@end
