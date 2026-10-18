// SPDX-License-Identifier: CC0-1.0
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Girasol's own Keychain group. The app may also read Opaline's group (for
/// the import), so every query of its own names this one: a query without
/// a group matches items in both, and a delete would remove Opaline's too.
@interface OPKeychainGroup : NSObject
/// Info.plist `OPKeychainGroup`; nil in a build that has none.
@property (class, nonatomic, readonly, nullable) NSString *own;
/// Adds `kSecAttrAccessGroup` = `own` to a query, when there is one.
+ (NSDictionary *)scoped:(NSDictionary *)query;
@end

NS_ASSUME_NONNULL_END
