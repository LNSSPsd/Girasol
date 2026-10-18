// SPDX-License-Identifier: CC0-1.0
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// A list row of the sheet.
@interface OPSheetAction : NSObject
+ (instancetype)actionWithTitle:(NSString *)title
                         symbol:(NSString *)symbol
                    destructive:(BOOL)destructive
                        handler:(void (^)(void))handler;
/// A check mark at the end of the row (the song is in this playlist).
@property (nonatomic) BOOL checked;
@end

/// A round on/off button of the sheet (Like): the state shows, and a tap
/// flips it right away and reports the new state.
@interface OPSheetToggle : NSObject
+ (instancetype)toggleWithTitle:(NSString *)title
                        onTitle:(NSString *)onTitle
                         symbol:(NSString *)symbol
                       onSymbol:(NSString *)onSymbol
                             on:(BOOL)on
                        handler:(void (^)(BOOL on))handler;
@end

/// The "…" sheet of a song: its artwork, title and artist on top, round
/// toggles, then actions (scrolling when they do not fit). Slides up over
/// the screen; tap outside or drag down to close. An action runs once the
/// sheet has gone, so it can put up a sheet of its own.
@interface OPTrackSheet : UIViewController
- (instancetype)initWithTitle:(NSString *)title subtitle:(NSString *)subtitle NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithNibName:(nullable NSString *)nibName bundle:(nullable NSBundle *)bundle NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

/// Shown at the left of the header, 56 pt square.
@property (nonatomic, strong, nullable) UIView *artworkView;
@property (nonatomic, copy) NSArray<OPSheetToggle *> *toggles;
@property (nonatomic, copy) NSArray<OPSheetAction *> *actions;
/// The artist line was tapped (after the sheet closes).
@property (nonatomic, copy, nullable) void (^onSubtitleTap)(void);

@property (nonatomic, strong) UIColor *cardColor;
@property (nonatomic, strong) UIColor *textColor;
@property (nonatomic, strong) UIColor *secondaryTextColor;
@property (nonatomic, strong) UIColor *accentColor;
@property (nonatomic, strong) UIColor *fillColor;

/// Presents it at once: the sheet animates itself in (dim and card
/// together), and the presentation is moved off the tap's own run-loop
/// turn, where UIKit can leave it waiting for the next event.
- (void)presentFrom:(UIViewController *)presenter;
@end

NS_ASSUME_NONNULL_END
