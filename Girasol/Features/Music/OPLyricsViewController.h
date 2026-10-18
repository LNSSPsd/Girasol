// SPDX-License-Identifier: CC0-1.0
#import <UIKit/UIKit.h>

@class OPLyrics;

NS_ASSUME_NONNULL_BEGIN

/// The lyrics screen, opened from the player's lyrics preview: large type,
/// free scrolling, and a tap on a synced line seeks there.
@interface OPLyricsViewController : UIViewController
- (instancetype)initWithLyrics:(OPLyrics *)lyrics
                         title:(NSString *)title
                        artist:(NSString *)artist NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithNibName:(nullable NSString *)nibName bundle:(nullable NSBundle *)bundle NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@property (nonatomic, strong) UIColor *backgroundColor;
@property (nonatomic, strong) UIColor *textColor;
@property (nonatomic, strong) UIColor *highlightColor;
/// Where the song is now; polled while the screen is up.
@property (nonatomic, copy, nullable) NSTimeInterval (^currentTime)(void);
@property (nonatomic, copy, nullable) void (^onSeek)(NSTimeInterval time);

/// The song changed while the screen is up: show its lyrics instead.
- (void)showLyrics:(OPLyrics *)lyrics title:(NSString *)title artist:(NSString *)artist;
@end

NS_ASSUME_NONNULL_END
