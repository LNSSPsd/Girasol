// SPDX-License-Identifier: CC0-1.0
#import "OPLyricsViewController.h"
#import "OPLyricsView.h"
#import "../../Core/Music/OPLyrics.h"

@interface OPLyricsViewController ()
@property (nonatomic, strong) OPLyrics *lyrics;
@property (nonatomic, copy) NSString *songTitle;
@property (nonatomic, copy) NSString *artist;
@property (nonatomic, strong) OPLyricsView *lyricsView;
@property (nonatomic, strong, nullable) NSTimer *timer;
@property (nonatomic, strong) UILabel *offsetLabel;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *artistLabel;
@end

@implementation OPLyricsViewController

- (instancetype)initWithLyrics:(OPLyrics *)lyrics title:(NSString *)title artist:(NSString *)artist {
	if ((self = [super initWithNibName:nil bundle:nil])) {
		_lyrics = lyrics;
		_songTitle = [title copy];
		_artist = [artist copy];
		_backgroundColor = UIColor.blackColor;
		_textColor = UIColor.lightGrayColor;
		_highlightColor = UIColor.whiteColor;
	}
	return self;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.view.backgroundColor = self.backgroundColor;

	UILabel *title = [UILabel new];
	self.titleLabel = title;
	title.text = self.songTitle;
	title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
	title.textColor = self.highlightColor;
	UILabel *artist = [UILabel new];
	self.artistLabel = artist;
	artist.text = self.artist;
	artist.font = [UIFont systemFontOfSize:15];
	artist.textColor = self.textColor;
	UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[ title, artist ]];
	header.axis = UILayoutConstraintAxisVertical;
	header.spacing = 2;

	UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
	[close setImage:[UIImage systemImageNamed:@"xmark"
	                        withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:20]]
	       forState:UIControlStateNormal];
	close.tintColor = self.highlightColor;
	[close addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];

	self.lyricsView = [OPLyricsView new];
	self.lyricsView.textColor = self.textColor;
	self.lyricsView.highlightColor = self.highlightColor;
	self.lyricsView.fontSize = 26;
	self.lyricsView.lyrics = self.lyrics;
	__weak typeof(self) weakSelf = self;
	self.lyricsView.onSeek = ^(NSTimeInterval time) {
		if (weakSelf.onSeek)
			weakSelf.onSeek(time);
	};

	// Timing nudge, for an entry timed against a different edit.
	UIButton *earlier = [self nudgeButton:@"backward.end" action:@selector(earlier)];
	UIButton *later = [self nudgeButton:@"forward.end" action:@selector(later)];
	self.offsetLabel = [UILabel new];
	self.offsetLabel.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightRegular];
	self.offsetLabel.textColor = self.textColor;
	self.offsetLabel.textAlignment = NSTextAlignmentCenter;
	UIStackView *nudge = [[UIStackView alloc] initWithArrangedSubviews:@[ earlier, self.offsetLabel, later ]];
	nudge.spacing = 12;
	[self updateOffsetLabel];

	for (UIView *view in @[ header, close, self.lyricsView, nudge ]) {
		view.translatesAutoresizingMaskIntoConstraints = NO;
		[self.view addSubview:view];
	}
	UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
	[NSLayoutConstraint activateConstraints:@[
		[close.topAnchor constraintEqualToAnchor:guide.topAnchor constant:8],
		[close.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-12],
		[close.widthAnchor constraintEqualToConstant:44],
		[close.heightAnchor constraintEqualToConstant:44],
		[header.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:24],
		[header.trailingAnchor constraintEqualToAnchor:close.leadingAnchor constant:-8],
		[header.centerYAnchor constraintEqualToAnchor:close.centerYAnchor],
		[self.lyricsView.topAnchor constraintEqualToAnchor:close.bottomAnchor constant:8],
		[self.lyricsView.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:16],
		[self.lyricsView.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-16],
		[self.lyricsView.bottomAnchor constraintEqualToAnchor:nudge.topAnchor constant:-8],
		[nudge.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
		[nudge.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor constant:-8],
		[self.offsetLabel.widthAnchor constraintEqualToConstant:140],
	]];
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	__weak typeof(self) weakSelf = self;
	self.timer = [NSTimer scheduledTimerWithTimeInterval:0.2
	                                             repeats:YES
	                                               block:^(NSTimer *timer) {
		                                               [weakSelf tick];
	                                               }];
	[self tick];
}

- (void)viewWillDisappear:(BOOL)animated {
	[super viewWillDisappear:animated];
	[self.timer invalidate];
	self.timer = nil;
}

- (void)tick {
	if (self.currentTime)
		[self.lyricsView updateTime:self.currentTime()];
}

- (UIButton *)nudgeButton:(NSString *)symbol action:(SEL)action {
	UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
	[button setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
	button.tintColor = self.highlightColor;
	[button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
	[button.widthAnchor constraintEqualToConstant:44].active = YES;
	[button.heightAnchor constraintEqualToConstant:44].active = YES;
	return button;
}

/// Lyrics a half second earlier: the highlight moves on sooner.
- (void)earlier {
	self.lyrics.offset += 0.5;
	[self updateOffsetLabel];
	[self tick];
}

- (void)later {
	self.lyrics.offset -= 0.5;
	[self updateOffsetLabel];
	[self tick];
}

- (void)updateOffsetLabel {
	NSTimeInterval offset = self.lyrics.offset;
	self.offsetLabel.text = offset == 0
	                            ? @"Timing: as is"
	                            : [NSString stringWithFormat:@"%@ %.1f s", offset > 0 ? @"Earlier" : @"Later", fabs(offset)];
	self.offsetLabel.hidden = !self.lyrics.synced;
}

- (void)showLyrics:(OPLyrics *)lyrics title:(NSString *)title artist:(NSString *)artist {
	self.lyrics = lyrics;
	self.songTitle = title;
	self.artist = artist;
	self.titleLabel.text = title;
	self.artistLabel.text = artist;
	self.lyricsView.lyrics = lyrics;
	[self updateOffsetLabel];
	[self tick];
}

- (void)close {
	[self dismissViewControllerAnimated:YES completion:nil];
}

- (UIStatusBarStyle)preferredStatusBarStyle {
	return UIStatusBarStyleLightContent;
}

@end
