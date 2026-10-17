#import "OPLyricsView.h"
#import "../../Core/Music/OPLyrics.h"

static NSString *const OPLyricsCellId = @"OPLyricsCell";
/// Space around a line's text inside its row.
static const CGFloat OPLineInsetX = 8;
static const CGFloat OPLineInsetY = 8;

/// One line: a label with fixed insets, so a row's height can be computed
/// exactly up front instead of estimated.
@interface OPLyricsCell : UITableViewCell
@property (nonatomic, strong) UILabel *line;
@end

@implementation OPLyricsCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
	if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
		self.backgroundColor = UIColor.clearColor;
		self.selectionStyle = UITableViewCellSelectionStyleNone;
		_line = [UILabel new];
		_line.numberOfLines = 0;
		_line.textAlignment = NSTextAlignmentCenter;
		_line.translatesAutoresizingMaskIntoConstraints = NO;
		[self.contentView addSubview:_line];
		[NSLayoutConstraint activateConstraints:@[
			[_line.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:OPLineInsetX],
			[_line.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-OPLineInsetX],
			[_line.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:OPLineInsetY],
			[_line.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-OPLineInsetY],
		]];
	}
	return self;
}
@end

@interface OPLyricsView () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UITapGestureRecognizer *previewTap;
@property (nonatomic) NSInteger currentLine;
/// Row heights for the current width; recomputed when either changes.
@property (nonatomic, strong) NSArray<NSNumber *> *rowHeights;
@property (nonatomic) CGFloat measuredWidth;
/// Size the position was last set for: opening the lyrics mid-song lays the
/// view out more than once, and the height arrives after the width.
@property (nonatomic) CGSize laidOutSize;
/// The current line has not been centered in a laid-out view yet: every
/// time update tries again until it has, instead of waiting for the next
/// line (a screen opened mid-song gets its size in several passes).
@property (nonatomic) BOOL needsPosition;
/// The user scrolled by hand: leave the position alone for a few seconds.
@property (nonatomic, strong, nullable) NSDate *manualScrollUntil;
@end

@implementation OPLyricsView

- (instancetype)initWithFrame:(CGRect)frame {
	if ((self = [super initWithFrame:frame])) {
		_textColor = UIColor.lightGrayColor;
		_highlightColor = UIColor.whiteColor;
		_fontSize = 17;
		_interactive = YES;
		_currentLine = -1;
		_rowHeights = @[];
		_tableView = [[UITableView alloc] initWithFrame:self.bounds style:UITableViewStylePlain];
		_tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
		_tableView.backgroundColor = UIColor.clearColor;
		_tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
		_tableView.showsVerticalScrollIndicator = NO;
		_tableView.estimatedRowHeight = 0;
		_tableView.dataSource = self;
		_tableView.delegate = self;
		[_tableView registerClass:OPLyricsCell.class forCellReuseIdentifier:OPLyricsCellId];
		[self addSubview:_tableView];
		// Only the preview takes taps as a whole; on the lyrics screen this
		// would swallow the taps meant for single lines.
		_previewTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped)];
		_previewTap.enabled = NO;
		[self addGestureRecognizer:_previewTap];
	}
	return self;
}

- (UIFont *)lineFont {
	return [UIFont systemFontOfSize:self.fontSize weight:UIFontWeightBold];
}

- (void)setInteractive:(BOOL)interactive {
	_interactive = interactive;
	self.tableView.userInteractionEnabled = interactive;
	self.previewTap.enabled = !interactive;
}

- (void)setFontSize:(CGFloat)fontSize {
	_fontSize = fontSize;
	[self remeasure];
}

- (void)setLyrics:(OPLyrics *)lyrics {
	_lyrics = lyrics;
	_currentLine = -1;
	_needsPosition = YES;
	[self remeasure];
	[self.tableView setContentOffset:CGPointMake(0, -self.tableView.contentInset.top) animated:NO];
}

- (void)tapped {
	if (self.onTap)
		self.onTap();
}

#pragma mark - Layout

- (void)layoutSubviews {
	[super layoutSubviews];
	// Room above and below so the first and last lines can sit centered.
	CGFloat pad = MAX(self.bounds.size.height / 2 - 20, 0);
	UIEdgeInsets inset = UIEdgeInsetsMake(pad, 0, pad, 0);
	if (!UIEdgeInsetsEqualToEdgeInsets(self.tableView.contentInset, inset))
		self.tableView.contentInset = inset;
	if (self.bounds.size.width != self.measuredWidth)
		[self remeasure];
	if (!CGSizeEqualToSize(self.bounds.size, self.laidOutSize)) {
		self.laidOutSize = self.bounds.size;
		self.needsPosition = YES;
		[self positionIfNeeded];
	}
}

/// Every row's exact height at this width. Every line uses the same font —
/// the current one is only brighter — so moving the highlight never resizes
/// a row under a running scroll.
- (void)remeasure {
	CGFloat width = self.bounds.size.width - 2 * OPLineInsetX;
	self.measuredWidth = self.bounds.size.width;
	NSMutableArray<NSNumber *> *heights = [NSMutableArray array];
	NSDictionary *attributes = @{NSFontAttributeName : self.lineFont};
	for (OPLyricLine *line in self.lyrics.lines) {
		CGRect box = [[self displayText:line] boundingRectWithSize:CGSizeMake(MAX(width, 1), CGFLOAT_MAX)
		                                                   options:NSStringDrawingUsesLineFragmentOrigin
		                                                attributes:attributes
		                                                   context:nil];
		[heights addObject:@(ceil(box.size.height) + 2 * OPLineInsetY)];
	}
	self.rowHeights = heights;
	[self.tableView reloadData];
}

- (NSString *)displayText:(OPLyricLine *)line {
	return line.text.length ? line.text : @"♪";
}

#pragma mark - Following the song

- (void)updateTime:(NSTimeInterval)time {
	if (!self.lyrics.synced)
		return;
	NSInteger line = [self.lyrics lineIndexAtTime:time];
	if (line == self.currentLine) {
		[self positionIfNeeded];
		return;
	}
	// The first position after new lyrics (or a freshly opened screen) is
	// a jump, not a glide from the top.
	BOOL animated = self.currentLine >= 0;
	self.currentLine = line;
	// Recolor the rows on screen in place: a reload would rebuild them in
	// the middle of the scroll below. Only the labels whose color changes
	// cross-dissolve (the old and the new line); a transition on the whole
	// table snapshotted every row at every line, 50-80 ms each time.
	for (OPLyricsCell *cell in self.tableView.visibleCells) {
		NSIndexPath *path = [self.tableView indexPathForCell:cell];
		if (!path)
			continue;
		UIColor *before = cell.line.textColor;
		CGFloat alpha = cell.line.alpha;
		[self style:cell row:path.row];
		if (![cell.line.textColor isEqual:before]) {
			UIColor *after = cell.line.textColor;
			cell.line.textColor = before;
			[UIView transitionWithView:cell.line
			                  duration:0.25
			                   options:UIViewAnimationOptionTransitionCrossDissolve |
			                           UIViewAnimationOptionAllowUserInteraction
			                animations:^{
				                cell.line.textColor = after;
			                }
			                completion:nil];
		}
		if (cell.line.alpha != alpha) {
			CGFloat target = cell.line.alpha;
			cell.line.alpha = alpha;
			[UIView animateWithDuration:0.25
			                      delay:0
			                    options:UIViewAnimationOptionAllowUserInteraction
			                 animations:^{
				                 cell.line.alpha = target;
			                 }
			                 completion:nil];
		}
	}
	BOOL userScrolling = self.manualScrollUntil && [self.manualScrollUntil timeIntervalSinceNow] > 0;
	if (!userScrolling)
		[self scrollToCurrentAnimated:animated && !self.needsPosition];
	if (!animated || self.needsPosition)
		[self positionIfNeeded];
}

/// Jumps to the current line once the view has a real size and its rows
/// are measured for it; until then it stays pending.
- (void)positionIfNeeded {
	if (!self.needsPosition || self.currentLine < 0)
		return;
	if (self.window == nil || self.bounds.size.height < 1 ||
	    self.measuredWidth != self.bounds.size.width || self.rowHeights.count != self.lyrics.lines.count)
		return;
	[self.tableView layoutIfNeeded];
	[self scrollToCurrentAnimated:NO];
	self.needsPosition = NO;
}

/// Puts the current line's center at the view's center — exact, from the
/// computed heights.
- (void)scrollToCurrentAnimated:(BOOL)animated {
	NSInteger line = self.currentLine;
	if (line < 0 || line >= (NSInteger)self.rowHeights.count)
		return;
	CGFloat top = 0;
	for (NSInteger i = 0; i < line; i++)
		top += self.rowHeights[i].doubleValue;
	CGFloat center = top + self.rowHeights[line].doubleValue / 2;
	CGPoint target = CGPointMake(0, center - self.bounds.size.height / 2);
	if (!animated) {
		self.tableView.contentOffset = target;
		return;
	}
	[UIView animateWithDuration:0.45
	                      delay:0
	                    options:UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionAllowUserInteraction |
	                            UIViewAnimationOptionBeginFromCurrentState
	                 animations:^{
		                 self.tableView.contentOffset = target;
	                 }
	                 completion:nil];
}

- (void)style:(OPLyricsCell *)cell row:(NSInteger)row {
	BOOL synced = self.lyrics.synced;
	BOOL current = synced && row == self.currentLine;
	cell.line.font = self.lineFont;
	cell.line.textColor = current || !synced ? self.highlightColor : self.textColor;
	// Lines already sung fade a little further than the ones to come.
	cell.line.alpha = current || !synced ? 1 : (row < self.currentLine ? 0.45 : 0.7);
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	return (NSInteger)self.lyrics.lines.count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
	return indexPath.row < (NSInteger)self.rowHeights.count ? self.rowHeights[indexPath.row].doubleValue : 44;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	OPLyricsCell *cell = [tableView dequeueReusableCellWithIdentifier:OPLyricsCellId forIndexPath:indexPath];
	cell.line.text = [self displayText:self.lyrics.lines[indexPath.row]];
	[self style:cell row:indexPath.row];
	return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	OPLyricLine *line = self.lyrics.lines[indexPath.row];
	if (self.lyrics.synced && line.time >= 0 && self.onSeek) {
		self.manualScrollUntil = nil;
		// Seek a hair past the stamp, net of the timing nudge, so the tapped
		// line is the one that lights up.
		self.onSeek(MAX(line.time - self.lyrics.offset - OPLyricsLead + 0.05, 0));
	}
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
	self.manualScrollUntil = [NSDate dateWithTimeIntervalSinceNow:4];
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
	self.manualScrollUntil = [NSDate dateWithTimeIntervalSinceNow:4];
}

@end
