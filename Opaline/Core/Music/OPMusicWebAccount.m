#import "OPMusicWebAccount.h"
#import "../Common/OPKeychainGroup.h"
#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>

NSNotificationName const OPMusicWebAccountDidChangeNotification = @"OPMusicWebAccountDidChange";

static NSString *const OPService = @"Opaline.MusicWebAccount";
static NSString *const OPAccount = @"cookies";

@implementation OPMusicWebAccount

static void (^sLogger)(NSString *);
/// The stored cookies, by "domain|path|name"; loaded once.
static NSMutableDictionary<NSString *, NSHTTPCookie *> *sCookies;

+ (void (^)(NSString *))logger {
	return sLogger;
}

+ (void)setLogger:(void (^)(NSString *))logger {
	sLogger = [logger copy];
}

+ (void)log:(NSString *)line {
	if (sLogger)
		sLogger(line);
}

+ (BOOL)signedIn {
	@synchronized(self) {
		return [self cookieNamed:@"SAPISID"] != nil;
	}
}

#pragma mark - Storage

+ (NSString *)keyFor:(NSHTTPCookie *)cookie {
	return [NSString stringWithFormat:@"%@|%@|%@", cookie.domain, cookie.path, cookie.name];
}

/// Only the parts that matter go to the Keychain, as a property list:
/// `NSHTTPCookie.properties` may hold values a plist cannot.
+ (NSDictionary *)plistFor:(NSHTTPCookie *)cookie {
	NSMutableDictionary *dict = [@{
		NSHTTPCookieName : cookie.name,
		NSHTTPCookieValue : cookie.value,
		NSHTTPCookieDomain : cookie.domain,
		NSHTTPCookiePath : cookie.path ?: @"/",
	} mutableCopy];
	if (cookie.expiresDate)
		dict[NSHTTPCookieExpires] = cookie.expiresDate;
	if (cookie.secure)
		dict[NSHTTPCookieSecure] = @"TRUE";
	return dict;
}

+ (NSDictionary *)keychainQuery {
	return [OPKeychainGroup scoped:@{
		(__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
		(__bridge id)kSecAttrService : OPService,
		(__bridge id)kSecAttrAccount : OPAccount,
	}];
}

/// Caller holds the lock.
+ (NSMutableDictionary<NSString *, NSHTTPCookie *> *)cookies {
	if (sCookies)
		return sCookies;
	sCookies = [NSMutableDictionary dictionary];
	NSMutableDictionary *query = [[self keychainQuery] mutableCopy];
	query[(__bridge id)kSecReturnData] = @YES;
	query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
	CFTypeRef result = NULL;
	if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &result) != errSecSuccess || !result)
		return sCookies;
	NSData *data = CFBridgingRelease(result);
	NSArray *list = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL];
	if (![list isKindOfClass:NSArray.class])
		return sCookies;
	NSDate *now = [NSDate date];
	for (NSDictionary *props in list) {
		NSHTTPCookie *cookie = [NSHTTPCookie cookieWithProperties:props];
		if (cookie && (!cookie.expiresDate || [cookie.expiresDate compare:now] == NSOrderedDescending))
			sCookies[[self keyFor:cookie]] = cookie;
	}
	return sCookies;
}

/// Caller holds the lock.
+ (void)persist {
	NSMutableArray *list = [NSMutableArray array];
	for (NSHTTPCookie *cookie in sCookies.allValues)
		[list addObject:[self plistFor:cookie]];
	NSData *data = [NSPropertyListSerialization dataWithPropertyList:list
	                                                          format:NSPropertyListBinaryFormat_v1_0
	                                                         options:0
	                                                           error:NULL];
	NSDictionary *query = [self keychainQuery];
	SecItemDelete((__bridge CFDictionaryRef)query);
	if (!data || sCookies.count == 0)
		return;
	NSMutableDictionary *add = [query mutableCopy];
	add[(__bridge id)kSecValueData] = data;
	// As with the TV tokens: readable in the background on a locked device.
	add[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlock;
	OSStatus status = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
	if (status != errSecSuccess)
		[self log:[NSString stringWithFormat:@"web account: keychain save failed (%d)", (int)status]];
}

/// Caller holds the lock. The `.youtube.com` one wins over a host-only copy.
+ (nullable NSHTTPCookie *)cookieNamed:(NSString *)name {
	NSHTTPCookie *found;
	for (NSHTTPCookie *cookie in [self cookies].allValues) {
		if (![cookie.name isEqualToString:name])
			continue;
		if (!found || [cookie.domain isEqualToString:@".youtube.com"])
			found = cookie;
	}
	return found;
}

+ (BOOL)isYouTubeDomain:(NSString *)domain {
	return [domain isEqualToString:@"youtube.com"] || [domain hasSuffix:@".youtube.com"];
}

+ (BOOL)saveCookies:(NSArray<NSHTTPCookie *> *)cookies {
	BOOL ok;
	NSUInteger count = 0;
	@synchronized(self) {
		NSMutableDictionary *previous = [[self cookies] mutableCopy];
		[sCookies removeAllObjects];
		for (NSHTTPCookie *cookie in cookies) {
			if ([self isYouTubeDomain:cookie.domain]) {
				sCookies[[self keyFor:cookie]] = cookie;
				count++;
			}
		}
		ok = [self cookieNamed:@"SAPISID"] != nil;
		if (ok)
			[self persist];
		else
			sCookies = previous;
	}
	[self log:[NSString stringWithFormat:@"web account: sign-in %@ (%lu YouTube cookies)", ok ? @"saved" : @"incomplete",
	                                     (unsigned long)count]];
	if (ok)
		[self postChange];
	return ok;
}

+ (void)signOut {
	@synchronized(self) {
		[[self cookies] removeAllObjects];
		[self persist];
	}
	[self log:@"web account: signed out"];
	[self postChange];
}

+ (void)postChange {
	dispatch_async(dispatch_get_main_queue(), ^{
		[NSNotificationCenter.defaultCenter postNotificationName:OPMusicWebAccountDidChangeNotification object:nil];
	});
}

#pragma mark - Requests

+ (NSString *)sha1:(NSString *)text {
	NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
	unsigned char digest[CC_SHA1_DIGEST_LENGTH];
	CC_SHA1(data.bytes, (CC_LONG)data.length, digest);
	NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
	for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++)
		[hex appendFormat:@"%02x", digest[i]];
	return hex;
}

+ (NSDictionary<NSString *, NSString *> *)headersForOrigin:(NSString *)origin {
	@synchronized(self) {
		NSHTTPCookie *sapisid = [self cookieNamed:@"SAPISID"];
		if (!sapisid)
			return nil;
		NSMutableArray *pairs = [NSMutableArray array];
		NSMutableSet *names = [NSMutableSet set];
		NSDate *now = [NSDate date];
		for (NSHTTPCookie *cookie in [self cookies].allValues) {
			if ((cookie.expiresDate && [cookie.expiresDate compare:now] != NSOrderedDescending) ||
			    [names containsObject:cookie.name])
				continue;
			[names addObject:cookie.name];
			[pairs addObject:[NSString stringWithFormat:@"%@=%@", cookie.name, cookie.value]];
		}
		// What the site sends: one hash per APISID flavour it holds, each
		// SHA1("<time> <cookie> <origin>").
		long long stamp = (long long)now.timeIntervalSince1970;
		NSMutableArray *auth = [NSMutableArray array];
		NSArray *flavours = @[
			@[ @"SAPISIDHASH", @"SAPISID" ], @[ @"SAPISID1PHASH", @"__Secure-1PAPISID" ],
			@[ @"SAPISID3PHASH", @"__Secure-3PAPISID" ]
		];
		for (NSArray *flavour in flavours) {
			NSHTTPCookie *cookie = [self cookieNamed:flavour[1]];
			if (!cookie)
				continue;
			NSString *hash =
			    [self sha1:[NSString stringWithFormat:@"%lld %@ %@", stamp, cookie.value, origin]];
			[auth addObject:[NSString stringWithFormat:@"%@ %lld_%@", flavour[0], stamp, hash]];
		}
		return @{
			@"Cookie" : [pairs componentsJoinedByString:@"; "],
			@"Authorization" : [auth componentsJoinedByString:@" "],
			@"X-Goog-AuthUser" : @"0",
			@"X-Origin" : origin,
		};
	}
}

+ (void)noteResponse:(NSURLResponse *)response {
	if (![response isKindOfClass:NSHTTPURLResponse.class] || !response.URL)
		return;
	NSDictionary *fields = ((NSHTTPURLResponse *)response).allHeaderFields;
	NSArray<NSHTTPCookie *> *fresh = [NSHTTPCookie cookiesWithResponseHeaderFields:fields forURL:response.URL];
	if (fresh.count == 0)
		return;
	NSMutableArray *changed = [NSMutableArray array];
	@synchronized(self) {
		if (![self cookieNamed:@"SAPISID"])
			return;
		NSDate *now = [NSDate date];
		for (NSHTTPCookie *cookie in fresh) {
			if (![self isYouTubeDomain:cookie.domain])
				continue;
			NSString *key = [self keyFor:cookie];
			NSHTTPCookie *old = sCookies[key];
			if (cookie.expiresDate && [cookie.expiresDate compare:now] != NSOrderedDescending) {
				// An expired Set-Cookie is a deletion; never drop the session
				// itself that way, a stray one would sign the user out.
				if (old && ![cookie.name hasSuffix:@"SID"]) {
					[sCookies removeObjectForKey:key];
					[changed addObject:cookie.name];
				}
				continue;
			}
			if (![old.value isEqualToString:cookie.value]) {
				sCookies[key] = cookie;
				[changed addObject:cookie.name];
			}
		}
		if (changed.count)
			[self persist];
	}
	if (changed.count)
		[self log:[NSString stringWithFormat:@"web account: cookies refreshed (%@)",
		                                     [changed componentsJoinedByString:@", "]]];
}

@end
