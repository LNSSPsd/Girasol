// SPDX-License-Identifier: CC0-1.0
#import "OPKeychainGroup.h"
#import <Security/Security.h>

@implementation OPKeychainGroup

+ (NSString *)own {
	NSString *group = [NSBundle.mainBundle objectForInfoDictionaryKey:@"OPKeychainGroup"];
	return [group isKindOfClass:NSString.class] && group.length > 0 ? group : nil;
}

+ (NSDictionary *)scoped:(NSDictionary *)query {
	NSString *group = self.own;
	if (!group)
		return query;
	NSMutableDictionary *scoped = [query mutableCopy];
	scoped[(__bridge id)kSecAttrAccessGroup] = group;
	return scoped;
}

@end
