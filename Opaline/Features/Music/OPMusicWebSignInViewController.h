// SPDX-License-Identifier: CC0-1.0
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Google sign-in in a web view, ending on music.youtube.com; its cookies
/// become `OPMusicWebAccount`. The web view's store is throwaway, so nothing
/// else in the app (video mode, the TV sign-in) sees this session.
@interface OPMusicWebSignInViewController : UIViewController
@property (nonatomic, strong) UIColor *backgroundColor;
/// YES once the session is saved; called after the screen closes itself.
@property (nonatomic, copy, nullable) void (^completion)(BOOL signedIn);
@end

NS_ASSUME_NONNULL_END
