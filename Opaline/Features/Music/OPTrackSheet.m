// SPDX-License-Identifier: CC0-1.0
#import "OPTrackSheet.h"

@interface OPSheetAction ()
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *symbol;
@property (nonatomic) BOOL destructive;
@property (nonatomic, copy) void (^handler)(void);
@end

@implementation OPSheetAction
+ (instancetype)actionWithTitle:(NSString *)title
                         symbol:(NSString *)symbol
                    destructive:(BOOL)destructive
                        handler:(void (^)(void))handler {
	OPSheetAction *action = [self new];
	action.title = title;
	action.symbol = symbol;
	action.destructive = destructive;
	action.handler = handler;
	return action;
}
@end

@interface OPSheetToggle ()
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *onTitle;
@property (nonatomic, copy) NSString *symbol;
@property (nonatomic, copy) NSString *onSymbol;
@property (nonatomic) BOOL on;
@property (nonatomic, copy) void (^handler)(BOOL);
@end

@implementation OPSheetToggle
+ (instancetype)toggleWithTitle:(NSString *)title
                        onTitle:(NSString *)onTitle
                         symbol:(NSString *)symbol
                       onSymbol:(NSString *)onSymbol
                             on:(BOOL)on
                        handler:(void (^)(BOOL))handler {
	OPSheetToggle *toggle = [self new];
	toggle.title = title;
	toggle.onTitle = onTitle;
	toggle.symbol = symbol;
	toggle.onSymbol = onSymbol;
	toggle.on = on;
	toggle.handler = handler;
	return toggle;
}
@end

@interface OPTrackSheet () <UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIScrollView *actionScroll;
@property (nonatomic, copy) NSString *songTitle;
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, strong) UIView *dim;
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) NSLayoutConstraint *cardBottom;
@property (nonatomic, strong) NSMutableArray<UIButton *> *toggleButtons;
@property (nonatomic, strong) NSMutableArray<UILabel *> *toggleLabels;
@end

@implementation OPTrackSheet

- (instancetype)initWithTitle:(NSString *)title subtitle:(NSString *)subtitle {
	if ((self = [super initWithNibName:nil bundle:nil])) {
		_songTitle = [title copy];
		_subtitle = [subtitle copy];
		_toggles = @[];
		_actions = @[];
		_cardColor = UIColor.secondarySystemBackgroundColor;
		_textColor = UIColor.labelColor;
		_secondaryTextColor = UIColor.secondaryLabelColor;
		_accentColor = UIColor.systemRedColor;
		_fillColor = UIColor.tertiarySystemFillColor;
		_toggleButtons = [NSMutableArray array];
		_toggleLabels = [NSMutableArray array];
		self.modalPresentationStyle = UIModalPresentationOverFullScreen;
	}
	return self;
}

- (void)presentFrom:(UIViewController *)presenter {
	dispatch_async(dispatch_get_main_queue(), ^{
		[presenter presentViewController:self animated:NO completion:nil];
	});
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.view.backgroundColor = UIColor.clearColor;
	self.dim = [UIView new];
	self.dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
	self.dim.alpha = 0;
	self.dim.translatesAutoresizingMaskIntoConstraints = NO;
	[self.dim addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(close)]];
	[self.view addSubview:self.dim];

	self.card = [UIView new];
	self.card.backgroundColor = self.cardColor;
	self.card.layer.cornerRadius = 16;
	self.card.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
	self.card.translatesAutoresizingMaskIntoConstraints = NO;
	UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)];
	pan.delegate = self;
	[self.card addGestureRecognizer:pan];
	[self.view addSubview:self.card];

	UIView *grabber = [UIView new];
	grabber.backgroundColor = self.fillColor;
	grabber.layer.cornerRadius = 2.5;

	UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[ [self header] ]];
	content.axis = UILayoutConstraintAxisVertical;
	content.spacing = 16;
	if (self.toggles.count)
		[content addArrangedSubview:[self toggleRow]];
	UIView *list = [self actionList];
	self.actionScroll = [UIScrollView new];
	self.actionScroll.alwaysBounceVertical = NO;
	self.actionScroll.showsVerticalScrollIndicator = YES;
	list.translatesAutoresizingMaskIntoConstraints = NO;
	[self.actionScroll addSubview:list];
	// As tall as its rows, until the card would leave the screen: then it
	// gives way (the card's top limit is required) and scrolls.
	NSLayoutConstraint *fit = [self.actionScroll.heightAnchor constraintEqualToAnchor:list.heightAnchor];
	fit.priority = UILayoutPriorityDefaultHigh;
	[NSLayoutConstraint activateConstraints:@[
		fit,
		[list.topAnchor constraintEqualToAnchor:self.actionScroll.contentLayoutGuide.topAnchor],
		[list.bottomAnchor constraintEqualToAnchor:self.actionScroll.contentLayoutGuide.bottomAnchor],
		[list.leadingAnchor constraintEqualToAnchor:self.actionScroll.contentLayoutGuide.leadingAnchor],
		[list.trailingAnchor constraintEqualToAnchor:self.actionScroll.contentLayoutGuide.trailingAnchor],
		[list.widthAnchor constraintEqualToAnchor:self.actionScroll.frameLayoutGuide.widthAnchor],
	]];
	[content addArrangedSubview:self.actionScroll];

	for (UIView *view in @[ grabber, content ]) {
		view.translatesAutoresizingMaskIntoConstraints = NO;
		[self.card addSubview:view];
	}
	// Fully below the screen to start with, however tall the card (a long
	// playlist list is taller than any fixed offset).
	self.cardBottom = [self.card.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor
	                                                         constant:UIScreen.mainScreen.bounds.size.height];
	[NSLayoutConstraint activateConstraints:@[
		[self.dim.topAnchor constraintEqualToAnchor:self.view.topAnchor],
		[self.dim.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
		[self.dim.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
		[self.dim.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
		[self.card.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
		[self.card.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
		self.cardBottom,
		[self.card.topAnchor constraintGreaterThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:40],
		[grabber.topAnchor constraintEqualToAnchor:self.card.topAnchor constant:8],
		[grabber.centerXAnchor constraintEqualToAnchor:self.card.centerXAnchor],
		[grabber.widthAnchor constraintEqualToConstant:36],
		[grabber.heightAnchor constraintEqualToConstant:5],
		[content.topAnchor constraintEqualToAnchor:grabber.bottomAnchor constant:16],
		[content.leadingAnchor constraintEqualToAnchor:self.card.leadingAnchor constant:20],
		[content.trailingAnchor constraintEqualToAnchor:self.card.trailingAnchor constant:-20],
		[content.bottomAnchor constraintEqualToAnchor:self.card.safeAreaLayoutGuide.bottomAnchor constant:-12],
	]];
}

- (void)viewDidAppear:(BOOL)animated {
	[super viewDidAppear:animated];
	[self.view layoutIfNeeded];
	self.cardBottom.constant = 0;
	[UIView animateWithDuration:0.35
	                      delay:0
	     usingSpringWithDamping:0.9
	      initialSpringVelocity:0
	                    options:0
	                 animations:^{
		                 [self.view layoutIfNeeded];
		                 self.dim.alpha = 1;
	                 }
	                 completion:nil];
	[self.actionScroll flashScrollIndicators];
}

#pragma mark - Building

- (UIView *)header {
	UILabel *title = [UILabel new];
	title.text = self.songTitle;
	title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
	title.textColor = self.textColor;
	title.numberOfLines = 2;
	UILabel *subtitle = [UILabel new];
	subtitle.text = self.subtitle;
	subtitle.font = [UIFont systemFontOfSize:15];
	subtitle.textColor = self.onSubtitleTap ? self.accentColor : self.secondaryTextColor;
	if (self.onSubtitleTap) {
		subtitle.userInteractionEnabled = YES;
		[subtitle addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self
		                                                                       action:@selector(subtitleTapped)]];
	}
	UIStackView *text = [[UIStackView alloc] initWithArrangedSubviews:@[ title, subtitle ]];
	text.axis = UILayoutConstraintAxisVertical;
	text.spacing = 2;
	UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[ text ]];
	row.spacing = 12;
	row.alignment = UIStackViewAlignmentCenter;
	if (self.artworkView) {
		UIView *art = self.artworkView;
		art.clipsToBounds = YES;
		art.layer.cornerRadius = 6;
		art.translatesAutoresizingMaskIntoConstraints = NO;
		[art.widthAnchor constraintEqualToConstant:56].active = YES;
		[art.heightAnchor constraintEqualToConstant:56].active = YES;
		[row insertArrangedSubview:art atIndex:0];
	}
	return row;
}

- (UIView *)toggleRow {
	UIStackView *row = [UIStackView new];
	row.distribution = UIStackViewDistributionFillEqually;
	[self.toggles enumerateObjectsUsingBlock:^(OPSheetToggle *toggle, NSUInteger index, BOOL *stop) {
		UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
		button.tag = (NSInteger)index;
		button.layer.cornerRadius = 26;
		[button addTarget:self action:@selector(toggleTapped:) forControlEvents:UIControlEventTouchUpInside];
		[button.widthAnchor constraintEqualToConstant:52].active = YES;
		[button.heightAnchor constraintEqualToConstant:52].active = YES;
		UILabel *label = [UILabel new];
		label.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
		label.textAlignment = NSTextAlignmentCenter;
		UIStackView *cell = [[UIStackView alloc] initWithArrangedSubviews:@[ button, label ]];
		cell.axis = UILayoutConstraintAxisVertical;
		cell.alignment = UIStackViewAlignmentCenter;
		cell.spacing = 6;
		[row addArrangedSubview:cell];
		[self.toggleButtons addObject:button];
		[self.toggleLabels addObject:label];
		[self styleToggle:index];
	}];
	return row;
}

- (void)styleToggle:(NSUInteger)index {
	OPSheetToggle *toggle = self.toggles[index];
	UIButton *button = self.toggleButtons[index];
	UIImageSymbolConfiguration *size = [UIImageSymbolConfiguration configurationWithPointSize:20
	                                                                                 weight:UIImageSymbolWeightSemibold];
	[button setImage:[UIImage systemImageNamed:toggle.on ? toggle.onSymbol : toggle.symbol withConfiguration:size]
	        forState:UIControlStateNormal];
	button.tintColor = toggle.on ? UIColor.whiteColor : self.textColor;
	button.backgroundColor = toggle.on ? self.accentColor : self.fillColor;
	self.toggleLabels[index].text = toggle.on ? toggle.onTitle : toggle.title;
	self.toggleLabels[index].textColor = toggle.on ? self.accentColor : self.secondaryTextColor;
}

- (UIView *)actionList {
	UIStackView *list = [UIStackView new];
	list.axis = UILayoutConstraintAxisVertical;
	[self.actions enumerateObjectsUsingBlock:^(OPSheetAction *action, NSUInteger index, BOOL *stop) {
		UIButton *row = [UIButton buttonWithType:UIButtonTypeSystem];
		row.tag = (NSInteger)index;
		UIColor *color = action.destructive ? UIColor.systemRedColor : self.textColor;
		UIImageSymbolConfiguration *size = [UIImageSymbolConfiguration configurationWithPointSize:18];
		[row setImage:[UIImage systemImageNamed:action.symbol withConfiguration:size] forState:UIControlStateNormal];
		[row setTitle:[@"   " stringByAppendingString:action.title] forState:UIControlStateNormal];
		[row setTitleColor:color forState:UIControlStateNormal];
		row.tintColor = action.destructive ? UIColor.systemRedColor : self.secondaryTextColor;
		row.titleLabel.font = [UIFont systemFontOfSize:17];
		row.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
		[row.heightAnchor constraintEqualToConstant:50].active = YES;
		[row addTarget:self action:@selector(actionTapped:) forControlEvents:UIControlEventTouchUpInside];
		if (action.checked) {
			UIImageView *check = [[UIImageView alloc]
			    initWithImage:[UIImage systemImageNamed:@"checkmark"
			                          withConfiguration:[UIImageSymbolConfiguration
			                                                configurationWithPointSize:16
			                                                                    weight:UIImageSymbolWeightSemibold]]];
			check.tintColor = self.accentColor;
			check.translatesAutoresizingMaskIntoConstraints = NO;
			[row addSubview:check];
			[NSLayoutConstraint activateConstraints:@[
				[check.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
				[check.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
			]];
			row.titleEdgeInsets = UIEdgeInsetsMake(0, 0, 0, 28);
		}
		row.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
		[list addArrangedSubview:row];
	}];
	return list;
}

#pragma mark - Interaction

- (void)toggleTapped:(UIButton *)button {
	OPSheetToggle *toggle = self.toggles[(NSUInteger)button.tag];
	toggle.on = !toggle.on;
	[UIView transitionWithView:button
	                  duration:0.2
	                   options:UIViewAnimationOptionTransitionCrossDissolve
	                animations:^{
		                [self styleToggle:(NSUInteger)button.tag];
	                }
	                completion:nil];
	if (toggle.handler)
		toggle.handler(toggle.on);
}

- (void)actionTapped:(UIButton *)button {
	void (^handler)(void) = self.actions[(NSUInteger)button.tag].handler;
	[self closeThen:handler];
}

- (void)subtitleTapped {
	[self closeThen:self.onSubtitleTap];
}

- (void)close {
	[self closeThen:nil];
}

- (void)closeThen:(void (^)(void))then {
	self.cardBottom.constant = self.card.bounds.size.height;
	[UIView animateWithDuration:0.22
	    animations:^{
		    [self.view layoutIfNeeded];
		    self.dim.alpha = 0;
	    }
	    completion:^(BOOL finished) {
		    [self dismissViewControllerAnimated:NO
		                             completion:^{
			                             if (then)
				                             then();
		                             }];
	    }];
}

/// Inside a list that scrolls, a drag scrolls it; only one pulling down
/// from its top moves the card.
- (BOOL)gestureRecognizerShouldBegin:(UIPanGestureRecognizer *)pan {
	UIScrollView *scroll = self.actionScroll;
	BOOL scrolls = scroll.contentSize.height > scroll.bounds.size.height + 1;
	if (!scrolls || ![scroll pointInside:[pan locationInView:scroll] withEvent:nil])
		return YES;
	return scroll.contentOffset.y <= 0 && [pan velocityInView:self.view].y > 0;
}

/// Follows the finger down; far or fast enough closes it.
- (void)pan:(UIPanGestureRecognizer *)pan {
	CGFloat offset = MAX(0, [pan translationInView:self.view].y);
	switch (pan.state) {
	case UIGestureRecognizerStateChanged:
		self.cardBottom.constant = offset;
		break;
	case UIGestureRecognizerStateEnded:
	case UIGestureRecognizerStateCancelled:
		if (offset > self.card.bounds.size.height / 3 || [pan velocityInView:self.view].y > 800) {
			[self close];
		} else {
			self.cardBottom.constant = 0;
			[UIView animateWithDuration:0.25
			                 animations:^{
				                 [self.view layoutIfNeeded];
			                 }];
		}
		break;
	default:
		break;
	}
}

@end
