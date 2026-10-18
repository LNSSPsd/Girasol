// SPDX-License-Identifier: CC0-1.0
#import "OPActionToast.h"

/// Only one at a time: a new toast replaces the one on screen.
static __weak OPActionToast *OPCurrentToast;

@interface OPActionToast ()
@property (nonatomic, copy, nullable) void (^handler)(void);
@end

@implementation OPActionToast

+ (void)showText:(NSString *)text
     actionTitle:(NSString *)actionTitle
          inView:(UIView *)view
     bottomInset:(CGFloat)bottomInset
      background:(UIColor *)background
       textColor:(UIColor *)textColor
     actionColor:(UIColor *)actionColor
         handler:(void (^)(void))handler {
	[OPCurrentToast removeFromSuperview];
	OPActionToast *toast = [OPActionToast new];
	toast.handler = handler;
	toast.backgroundColor = background;
	toast.layer.cornerRadius = 12;
	toast.layer.shadowColor = UIColor.blackColor.CGColor;
	toast.layer.shadowOpacity = 0.25;
	toast.layer.shadowRadius = 8;
	toast.layer.shadowOffset = CGSizeMake(0, 2);

	UILabel *label = [UILabel new];
	label.text = text;
	label.textColor = textColor;
	label.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
	label.numberOfLines = 2;
	UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[ label ]];
	row.spacing = 12;
	row.alignment = UIStackViewAlignmentCenter;
	if (actionTitle) {
		UIButton *action = [UIButton buttonWithType:UIButtonTypeSystem];
		[action setTitle:actionTitle forState:UIControlStateNormal];
		action.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
		[action setTitleColor:actionColor forState:UIControlStateNormal];
		[action setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
		[action setContentCompressionResistancePriority:UILayoutPriorityRequired
		                                        forAxis:UILayoutConstraintAxisHorizontal];
		[action addTarget:toast action:@selector(actionTapped) forControlEvents:UIControlEventTouchUpInside];
		[row addArrangedSubview:action];
	}
	row.translatesAutoresizingMaskIntoConstraints = NO;
	[toast addSubview:row];
	toast.translatesAutoresizingMaskIntoConstraints = NO;
	[view addSubview:toast];
	[NSLayoutConstraint activateConstraints:@[
		[row.leadingAnchor constraintEqualToAnchor:toast.leadingAnchor constant:16],
		[row.trailingAnchor constraintEqualToAnchor:toast.trailingAnchor constant:-16],
		[row.topAnchor constraintEqualToAnchor:toast.topAnchor constant:12],
		[row.bottomAnchor constraintEqualToAnchor:toast.bottomAnchor constant:-12],
		[toast.leadingAnchor constraintEqualToAnchor:view.safeAreaLayoutGuide.leadingAnchor constant:16],
		[toast.trailingAnchor constraintEqualToAnchor:view.safeAreaLayoutGuide.trailingAnchor constant:-16],
		[toast.bottomAnchor constraintEqualToAnchor:view.safeAreaLayoutGuide.bottomAnchor constant:-bottomInset],
	]];
	OPCurrentToast = toast;
	toast.alpha = 0;
	toast.transform = CGAffineTransformMakeTranslation(0, 20);
	[UIView animateWithDuration:0.25
	                 animations:^{
		                 toast.alpha = 1;
		                 toast.transform = CGAffineTransformIdentity;
	                 }];
	// Long enough to reach the action button.
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		[toast dismiss];
	});
}

- (void)actionTapped {
	void (^handler)(void) = self.handler;
	self.handler = nil;
	[self dismiss];
	if (handler)
		handler();
}

- (void)dismiss {
	if (!self.superview)
		return;
	[UIView animateWithDuration:0.2
	    animations:^{
		    self.alpha = 0;
	    }
	    completion:^(BOOL finished) {
		    [self removeFromSuperview];
	    }];
}

@end
