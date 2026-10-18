#import "OPOpalineImport.h"
#import "OPKeychainGroup.h"
#import <Security/Security.h>
#import <sys/clonefile.h>

static NSString *const OPContainersPath = @"/var/mobile/Containers/Data/Application";
static NSString *const OPContainerMetadata = @".com.apple.mobile_container_manager.metadata.plist";

static void (^sLogger)(NSString *);

static void OPLog(NSString *text) {
	void (^logger)(NSString *) = sLogger;
	if (logger)
		logger([@"opaline import: " stringByAppendingString:text]);
}

static NSString *OPInfoString(NSString *key) {
	NSString *value = [NSBundle.mainBundle objectForInfoDictionaryKey:key];
	return [value isKindOfClass:NSString.class] && value.length > 0 ? value : nil;
}

/// Settings iOS and its frameworks keep in every app's defaults: not
/// Opaline's to hand over.
static BOOL OPIsSystemKey(NSString *key) {
	for (NSString *prefix in @[ @"Apple", @"NS", @"com.apple", @"WebKit", @"WebDatabase" ])
		if ([key hasPrefix:prefix])
			return YES;
	return NO;
}

static NSString *OPBytes(unsigned long long bytes) {
	return [NSByteCountFormatter stringFromByteCount:(long long)bytes countStyle:NSByteCountFormatterCountStyleFile];
}

@implementation OPOpalineImport

+ (void (^)(NSString *))logger {
	return sLogger;
}

+ (void)setLogger:(void (^)(NSString *))logger {
	sLogger = [logger copy];
}

+ (BOOL)available {
	return [[NSBundle.mainBundle objectForInfoDictionaryKey:@"OPOpalineImport"] isEqual:@"YES"];
}

+ (NSURL *)opalineContainer {
	static NSURL *found;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		found = [self findContainer];
	});
	return found;
}

+ (NSURL *)findContainer {
	NSString *identifier = OPInfoString(@"OPOpalineIdentifier");
	if (!self.available || !identifier)
		return nil;
	NSError *error;
	NSArray<NSString *> *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:OPContainersPath error:&error];
	if (!names) {
		// Sandboxed after all: the entitlement did not take.
		OPLog([NSString stringWithFormat:@"cannot list app containers (%@)", error.localizedDescription]);
		return nil;
	}
	NSString *own = NSHomeDirectory().stringByResolvingSymlinksInPath;
	for (NSString *name in names) {
		NSString *path = [OPContainersPath stringByAppendingPathComponent:name];
		if ([path.stringByResolvingSymlinksInPath isEqualToString:own])
			continue;
		NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:OPContainerMetadata]];
		if ([metadata[@"MCMMetadataIdentifier"] isEqual:identifier]) {
			OPLog([NSString stringWithFormat:@"%@ found (%@)", identifier, name]);
			return [NSURL fileURLWithPath:path isDirectory:YES];
		}
	}
	OPLog([NSString stringWithFormat:@"%@ not installed (%lu containers)", identifier, (unsigned long)names.count]);
	return nil;
}

+ (NSURL *)supportIn:(NSURL *)container {
	return [container URLByAppendingPathComponent:@"Library/Application Support" isDirectory:YES];
}

+ (unsigned long long)sizeOfFilesIn:(NSURL *)container {
	unsigned long long total = 0;
	NSDirectoryEnumerator *walk = [NSFileManager.defaultManager enumeratorAtURL:[self supportIn:container]
	                                                 includingPropertiesForKeys:@[ NSURLFileSizeKey ]
	                                                                    options:0
	                                                               errorHandler:nil];
	for (NSURL *url in walk) {
		NSNumber *size;
		[url getResourceValue:&size forKey:NSURLFileSizeKey error:NULL];
		total += size.unsignedLongLongValue;
	}
	return total;
}

+ (void)runImportFrom:(NSURL *)container
           completion:(void (^)(NSString *_Nullable, NSString *_Nullable))completion {
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSString *failure;
		NSUInteger settings = [self importSettingsFrom:container];
		NSUInteger signIns = [self importKeychain];
		unsigned long long bytes = 0;
		NSUInteger files = [self importFilesFrom:container bytes:&bytes failure:&failure];
		[NSUserDefaults.standardUserDefaults synchronize];
		NSString *summary = [NSString stringWithFormat:@"%lu settings, %lu sign-ins, %lu folders (%@)",
		                                               (unsigned long)settings, (unsigned long)signIns,
		                                               (unsigned long)files, OPBytes(bytes)];
		OPLog(failure ? [NSString stringWithFormat:@"%@; failed: %@", summary, failure] : summary);
		dispatch_async(dispatch_get_main_queue(), ^{
			completion(failure ? nil : summary, failure);
		});
	});
}

/// Opaline's defaults, read from its preferences file (it is Opaline's
/// cfprefsd domain, not ours, so no API reads it).
+ (NSUInteger)importSettingsFrom:(NSURL *)container {
	NSString *identifier = OPInfoString(@"OPOpalineIdentifier");
	NSURL *file = [container URLByAppendingPathComponent:
	                             [NSString stringWithFormat:@"Library/Preferences/%@.plist", identifier]];
	NSDictionary *values = [NSDictionary dictionaryWithContentsOfURL:file];
	if (!values) {
		OPLog(@"no settings file");
		return 0;
	}
	NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
	NSUInteger count = 0;
	for (NSString *key in values) {
		if (![key isKindOfClass:NSString.class] || OPIsSystemKey(key))
			continue;
		[defaults setObject:values[key] forKey:key];
		count++;
	}
	return count;
}

/// Every password item of Opaline's group, rewritten into Girasol's own.
+ (NSUInteger)importKeychain {
	NSString *group = OPInfoString(@"OPOpalineKeychainGroup");
	if (!group || !OPKeychainGroup.own)
		return 0;
	NSDictionary *query = @{
		(__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
		(__bridge id)kSecAttrAccessGroup : group,
		(__bridge id)kSecMatchLimit : (__bridge id)kSecMatchLimitAll,
		(__bridge id)kSecReturnAttributes : @YES,
		(__bridge id)kSecReturnData : @YES,
	};
	CFTypeRef result = NULL;
	OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
	if (status != errSecSuccess) {
		// -34018: the Keychain group entitlement did not take; -25300: none.
		OPLog([NSString stringWithFormat:@"no Keychain items read from %@ (%d)", group, (int)status]);
		return 0;
	}
	NSArray<NSDictionary *> *items = CFBridgingRelease(result);
	NSUInteger count = 0;
	for (NSDictionary *item in items) {
		NSString *service = item[(__bridge id)kSecAttrService];
		NSString *account = item[(__bridge id)kSecAttrAccount];
		NSData *data = item[(__bridge id)kSecValueData];
		if (!service || !account || !data)
			continue;
		NSDictionary *own = [OPKeychainGroup scoped:@{
			(__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
			(__bridge id)kSecAttrService : service,
			(__bridge id)kSecAttrAccount : account,
		}];
		SecItemDelete((__bridge CFDictionaryRef)own);
		NSMutableDictionary *add = [own mutableCopy];
		add[(__bridge id)kSecValueData] = data;
		add[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlock;
		OSStatus added = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
		if (added == errSecSuccess)
			count++;
		else
			OPLog([NSString stringWithFormat:@"Keychain item %@ not copied (%d)", service, (int)added]);
	}
	return count;
}

/// Application Support, item by item over Girasol's own. A clone first
/// (APFS: no extra space until either copy changes), a copy if that fails.
+ (NSUInteger)importFilesFrom:(NSURL *)container
                        bytes:(unsigned long long *)bytes
                      failure:(NSString **)failure {
	NSFileManager *files = NSFileManager.defaultManager;
	NSURL *source = [self supportIn:container];
	NSURL *target = [files URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
	[files createDirectoryAtURL:target withIntermediateDirectories:YES attributes:nil error:NULL];
	NSArray<NSURL *> *items = [files contentsOfDirectoryAtURL:source includingPropertiesForKeys:nil options:0 error:NULL];
	NSUInteger count = 0;
	*bytes = [self sizeOfFilesIn:container];
	for (NSURL *item in items) {
		NSURL *destination = [target URLByAppendingPathComponent:item.lastPathComponent];
		[files removeItemAtURL:destination error:NULL];
		if (clonefile(item.fileSystemRepresentation, destination.fileSystemRepresentation, 0) == 0) {
			count++;
			continue;
		}
		int cloneError = errno;
		NSError *error;
		if ([files copyItemAtURL:item toURL:destination error:&error]) {
			OPLog([NSString stringWithFormat:@"%@ copied (no clone: errno %d)", item.lastPathComponent, cloneError]);
			count++;
		} else {
			*failure = [NSString stringWithFormat:@"%@: %@", item.lastPathComponent, error.localizedDescription];
			return count;
		}
	}
	return count;
}

@end
