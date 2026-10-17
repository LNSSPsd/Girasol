#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted on the main queue when the web account signs in or out.
FOUNDATION_EXPORT NSNotificationName const OPMusicWebAccountDidChangeNotification;

/// The optional YouTube Music web sign-in: the cookies of a music.youtube.com
/// session, kept in the Keychain. The TV token cannot reach the YouTube Music
/// home feed or create playlists; a web session
/// can, with WEB_REMIX and a SAPISIDHASH header, the way the site itself does
/// it. Everything else works without it.
@interface OPMusicWebAccount : NSObject
@property (class, nonatomic, readonly) BOOL signedIn;
/// Where log lines go (the app's log lives in Swift).
@property (class, nonatomic, copy, nullable) void (^logger)(NSString *line);

/// Cookie, Authorization and X-Goog-AuthUser for a request from `origin`
/// (e.g. "https://music.youtube.com"); nil when signed out.
+ (nullable NSDictionary<NSString *, NSString *> *)headersForOrigin:(NSString *)origin;
/// Keeps rotated cookies: Google refreshes some of them through Set-Cookie,
/// and a session that keeps sending stale ones is eventually dropped.
+ (void)noteResponse:(nullable NSURLResponse *)response;
/// Keeps the YouTube cookies of a finished web sign-in; NO when they do not
/// make a session (no SAPISID).
+ (BOOL)saveCookies:(NSArray<NSHTTPCookie *> *)cookies;
+ (void)signOut;
+ (void)log:(NSString *)line;
@end

NS_ASSUME_NONNULL_END
