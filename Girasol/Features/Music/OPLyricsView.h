// SPDX-License-Identifier: CC0-1.0
#import <UIKit/UIKit.h>

@class OPLyrics;

NS_ASSUME_NONNULL_BEGIN

/// Lyrics that follow the song: synced lyrics keep the current line
/// centered and highlighted. Interactive (the lyrics screen) it scrolls and
/// a tap on a line seeks to it; as a preview (under the player controls) it
/// only follows, and a tap anywhere calls `onTap`.
@interface OPLyricsView : UIView
@property (nonatomic, strong, nullable) OPLyrics *lyrics;
@property (nonatomic, strong) UIColor *textColor;
@property (nonatomic, strong) UIColor *highlightColor;
/// Size of a line; the current one is drawn a little larger. Default 17.
@property (nonatomic) CGFloat fontSize;
/// NO for the preview: no scrolling or seeking. Default YES.
@property (nonatomic, getter=isInteractive) BOOL interactive;
/// Called with a synced line's start time when the line is tapped.
@property (nonatomic, copy, nullable) void (^onSeek)(NSTimeInterval time);
/// The preview was tapped.
@property (nonatomic, copy, nullable) void (^onTap)(void);

/// Moves the highlight to the line playing at `time`.
- (void)updateTime:(NSTimeInterval)time;
@end

NS_ASSUME_NONNULL_END
