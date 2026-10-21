// SPDX-License-Identifier: CC0-1.0
#import "OPKeepAlive.h"
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>

static AVAudioPlayer *OPSilence;
/// UIBackgroundTaskInvalid, which C does not take as a constant.
static UIBackgroundTaskIdentifier OPTask = 0;

/// One second of 8 kHz mono 16-bit silence as a WAV file, looped.
static NSData *OPSilentWave(void) {
	const uint32_t rate = 8000, samples = rate, bytes = samples * 2;
	NSMutableData *data = [NSMutableData dataWithCapacity:44 + bytes];
	void (^u32)(uint32_t) = ^(uint32_t value) {
		uint32_t le = CFSwapInt32HostToLittle(value);
		[data appendBytes:&le length:4];
	};
	void (^u16)(uint16_t) = ^(uint16_t value) {
		uint16_t le = CFSwapInt16HostToLittle(value);
		[data appendBytes:&le length:2];
	};
	[data appendBytes:"RIFF" length:4];
	u32(36 + bytes);
	[data appendBytes:"WAVEfmt " length:8];
	u32(16);
	u16(1);        // PCM
	u16(1);        // mono
	u32(rate);
	u32(rate * 2); // bytes per second
	u16(2);        // block align
	u16(16);       // bits per sample
	[data appendBytes:"data" length:4];
	u32(bytes);
	[data increaseLengthBy:bytes];
	return data;
}

@implementation OPKeepAlive

+ (BOOL)isActive {
	return OPSilence != nil;
}

+ (void)setActive:(BOOL)active {
	if (active == (OPSilence != nil)) {
		return;
	}
	UIApplication *app = UIApplication.sharedApplication;
	if (!active) {
		[OPSilence stop];
		OPSilence = nil;
		if (OPTask != UIBackgroundTaskInvalid) {
			[app endBackgroundTask:OPTask];
			OPTask = UIBackgroundTaskInvalid;
		}
		return;
	}
	if (OPTask == UIBackgroundTaskInvalid) {
		OPTask = [app beginBackgroundTaskWithName:@"music keep-alive" expirationHandler:^{
			[app endBackgroundTask:OPTask];
			OPTask = UIBackgroundTaskInvalid;
		}];
	}
	NSError *error;
	OPSilence = [[AVAudioPlayer alloc] initWithData:OPSilentWave() error:&error];
	OPSilence.numberOfLoops = -1;
	if (![OPSilence play]) {
		NSLog(@"keep-alive: silence would not play (%@)", error);
	}
}

@end

@implementation OPNetworkProbe

+ (NSURLSession *)session {
	static NSURLSession *session;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
		config.timeoutIntervalForRequest = 6;
		config.timeoutIntervalForResource = 6;
		config.HTTPCookieStorage = nil;
		config.URLCache = nil;
		config.waitsForConnectivity = NO;
		session = [NSURLSession sessionWithConfiguration:config];
	});
	return session;
}

+ (void)probe:(void (^)(BOOL reachable))completion {
	NSURL *url = [NSURL URLWithString:@"https://www.youtube.com/generate_204"];
	NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
	request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
	[[self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
		BOOL reachable = error == nil && [(NSHTTPURLResponse *)response statusCode] == 204;
		dispatch_async(dispatch_get_main_queue(), ^{
			completion(reachable);
		});
	}] resume];
}

@end
