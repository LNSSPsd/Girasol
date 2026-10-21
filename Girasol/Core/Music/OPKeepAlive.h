// SPDX-License-Identifier: CC0-1.0
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Keeps the app running in the background while music is meant to be
/// playing but nothing is audible: a stream waiting for a network that does
/// not answer, or a song that will not start. iOS suspends a background app
/// soon after its audio stops, and a suspended app cannot retry or switch
/// to a song on the device. Silence played through the app's own audio
/// session counts as audio; a background task covers the moment before it
/// starts. Main queue only.
@interface OPKeepAlive : NSObject
@property (class, nonatomic, readonly) BOOL isActive;
+ (void)setActive:(BOOL)active;
@end

/// Whether YouTube answers at all, asked with a request that costs nothing:
/// `generate_204` must come back as 204 within a few seconds (a captive
/// portal's page or a connection that crawls count as no network).
@interface OPNetworkProbe : NSObject
/// Calls back on the main queue.
+ (void)probe:(void (^)(BOOL reachable))completion;
@end

NS_ASSUME_NONNULL_END
