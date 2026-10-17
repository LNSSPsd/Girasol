#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Music settings: caching ahead, and a way on to the app's settings.
@interface OPMusicSettingsViewController : UITableViewController
@property (nonatomic, strong) UIColor *backgroundColor;
@property (nonatomic, strong) UIColor *cellColor;
@property (nonatomic, strong) UIColor *textColor;
@property (nonatomic, strong) UIColor *secondaryTextColor;
@property (nonatomic, strong) UIColor *accentColor;
/// "App settings": opens Opaline's own settings.
@property (nonatomic, copy, nullable) void (^onAppSettings)(void);
@end

NS_ASSUME_NONNULL_END
