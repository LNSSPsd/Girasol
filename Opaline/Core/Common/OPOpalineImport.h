#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Brings Opaline's data into Girasol in one go: settings, the Keychain
/// sign-ins (TV and YouTube Music web account) and Application Support
/// (downloads, saved songs, lyrics, the music session and its lists).
/// Opaline means the app installed as `OPOpalineIdentifier`, which includes
/// this fork from before its rename. Opaline itself is left as it was.
///
/// Needs the TrollStore entitlements the Makefile signs with: no-sandbox
/// (to read Opaline's container) and Opaline's Keychain group. A sandboxed
/// build (`make SANDBOX=1`) has neither and turns the import off.
@interface OPOpalineImport : NSObject

/// AppLog's line writer (set at launch).
@property (class, nonatomic, copy, nullable) void (^logger)(NSString *line);

/// Whether this build can import at all (Info.plist `OPOpalineImport`).
@property (class, nonatomic, readonly) BOOL available;

/// Opaline's data container, when the import is available and Opaline is
/// installed and readable; nil otherwise. Scans the data containers once
/// per launch.
@property (class, nonatomic, readonly, nullable) NSURL *opalineContainer;

/// The size of what would be copied (Application Support), in bytes.
+ (unsigned long long)sizeOfFilesIn:(NSURL *)container;

/// Copies everything over Girasol's own (what Girasol had of the same is
/// replaced). Runs on a background queue; `completion` on the main queue
/// with a short summary, or nil and the reason on failure. The app must
/// not keep running afterwards: what it holds in memory is stale.
+ (void)runImportFrom:(NSURL *)container
           completion:(void (^)(NSString *_Nullable summary, NSString *_Nullable failure))completion
    NS_SWIFT_NAME(runImport(from:completion:));

@end

NS_ASSUME_NONNULL_END
