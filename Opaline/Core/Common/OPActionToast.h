#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// A toast with one action button ("Added to My playlist · Change"), shown at
/// the bottom of a view for a few seconds.
@interface OPActionToast : UIView
+ (void)showText:(NSString *)text
     actionTitle:(nullable NSString *)actionTitle
          inView:(UIView *)view
     bottomInset:(CGFloat)bottomInset
      background:(UIColor *)background
       textColor:(UIColor *)textColor
     actionColor:(UIColor *)actionColor
         handler:(nullable void (^)(void))handler;
@end

NS_ASSUME_NONNULL_END
