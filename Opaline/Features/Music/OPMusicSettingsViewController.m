#import "OPMusicSettingsViewController.h"
#import "../../Core/Music/OPMusicSettings.h"
#import "../../Core/Music/OPMusicWebAccount.h"
#import "OPMusicWebSignInViewController.h"

typedef NS_ENUM(NSInteger, OPSection) {
	OPSectionSearch,
	OPSectionSongs,
	OPSectionTitles,
	OPSectionLevel,
	OPSectionCrossfade,
	OPSectionCache,
	OPSectionAmount,
	OPSectionDisk,
	OPSectionAccount,
	OPSectionAfter,
	OPSectionApp,
	OPSectionCount,
};

@implementation OPMusicSettingsViewController

- (instancetype)init {
	if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
		_backgroundColor = UIColor.systemGroupedBackgroundColor;
		_cellColor = UIColor.secondarySystemGroupedBackgroundColor;
		_textColor = UIColor.labelColor;
		_secondaryTextColor = UIColor.secondaryLabelColor;
		_accentColor = UIColor.systemRedColor;
		self.title = @"Music settings";
	}
	return self;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.tableView.backgroundColor = self.backgroundColor;
	self.navigationItem.rightBarButtonItem =
	    [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
	                                                  target:self
	                                                  action:@selector(done)];
	[NSNotificationCenter.defaultCenter addObserver:self
	                                       selector:@selector(accountChanged)
	                                           name:OPMusicWebAccountDidChangeNotification
	                                         object:nil];
}

- (void)accountChanged {
	NSMutableIndexSet *sections = [NSMutableIndexSet indexSetWithIndex:OPSectionAccount];
	[sections addIndex:OPSectionAfter];
	[self.tableView reloadSections:sections withRowAnimation:UITableViewRowAnimationNone];
}

- (void)done {
	[self dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
	return OPSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	switch (section) {
	case OPSectionSearch:
	case OPSectionSongs:
	case OPSectionTitles:
	case OPSectionLevel:
	case OPSectionCache:
		return 1;
	case OPSectionAmount:
		return OPMusicSettings.cacheNext ? (NSInteger)OPMusicSettings.cacheChoices.count : 0;
	case OPSectionCrossfade:
		return (NSInteger)OPMusicSettings.crossfadeChoices.count;
	case OPSectionDisk:
		return (NSInteger)OPMusicSettings.diskCacheChoices.count;
	default:
		return 1;
	}
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
	if (section == OPSectionAmount && OPMusicSettings.cacheNext)
		return @"How much to buffer ahead";
	if (section == OPSectionCrossfade)
		return @"Crossfade";
	if (section == OPSectionAfter)
		return @"After an album or playlist";
	if (section == OPSectionDisk)
		return @"Keep played songs";
	return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
	if (section == OPSectionSearch)
		return @"Off: results come when you tap Search on the keyboard.";
	if (section == OPSectionSongs)
		return @"YouTube Music often lists a song's music video in its place, which can differ from the album "
		       @"version (a radio edit, an intro). On: the album version plays.";
	if (section == OPSectionTitles)
		return @"In English, YouTube Music adds a romanized name to Japanese songs and romanizes Japanese artists "
		       @"and albums. On: Japanese songs, artists and albums keep their original names. Applies to lists "
		       @"loaded from now on.";
	if (section == OPSectionLevel)
		return @"Songs mastered louder than YouTube's loudness target are turned down to it, as YouTube's own "
		       @"players do, so one song does not blast after a quiet one.";
	if (section == OPSectionCrossfade)
		return @"Each song fades into the next. Albums always play gapless, as they were made; it needs "
		       @"\"Cache the next song\" on.";
	if (section == OPSectionCache)
		return @"Loads the next song before the current one ends, so a tunnel or a dead zone does not stop the "
		       @"music.";
	if (section == OPSectionAmount && OPMusicSettings.cacheNext)
		return @"Applies to the playing song and the next one. More uses more data up front.";
	if (section == OPSectionDisk)
		return @"Songs are saved as they stream, so a song played again starts at once, uses no data and "
		       @"plays offline (◌ in lists; ↓ is a download). When full, the songs played least lately go "
		       @"first. Off: songs stream straight from YouTube and nothing is kept.";
	if (section == OPSectionAccount)
		return OPMusicWebAccount.signedIn
		           ? @"Home shows your own YouTube Music shelves, and new playlists can be created."
		           : @"Optional. Everything else works with the app's sign-in alone; this adds your personal "
		             @"YouTube Music home and creating playlists, which YouTube allows only to a web sign-in.";
	if (section == OPSectionAfter)
		return OPMusicWebAccount.signedIn
		           ? @"On: what YouTube Music itself plays after that album or playlist, for your account. Off: a mix "
		             @"of the songs you played lately."
		           : @"Plays a mix of the songs you played lately. YouTube Music's own recommendations need the "
		             @"YouTube Music sign-in above.";
	return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
	cell.backgroundColor = self.cellColor;
	cell.textLabel.textColor = self.textColor;
	cell.tintColor = self.accentColor;
	switch (indexPath.section) {
	case OPSectionSearch: {
		cell.textLabel.text = @"Search as you type";
		cell.selectionStyle = UITableViewCellSelectionStyleNone;
		UISwitch *toggle = [UISwitch new];
		toggle.on = OPMusicSettings.searchAsYouType;
		toggle.onTintColor = self.accentColor;
		[toggle addTarget:self action:@selector(searchToggled:) forControlEvents:UIControlEventValueChanged];
		cell.accessoryView = toggle;
		break;
	}
	case OPSectionSongs: {
		cell.textLabel.text = @"Songs, not music videos";
		cell.selectionStyle = UITableViewCellSelectionStyleNone;
		UISwitch *toggle = [UISwitch new];
		toggle.on = OPMusicSettings.songVersions;
		toggle.onTintColor = self.accentColor;
		[toggle addTarget:self action:@selector(songsToggled:) forControlEvents:UIControlEventValueChanged];
		cell.accessoryView = toggle;
		break;
	}
	case OPSectionTitles: {
		cell.textLabel.text = @"Original Japanese titles";
		cell.selectionStyle = UITableViewCellSelectionStyleNone;
		UISwitch *toggle = [UISwitch new];
		toggle.on = OPMusicSettings.originalTitles;
		toggle.onTintColor = self.accentColor;
		[toggle addTarget:self action:@selector(titlesToggled:) forControlEvents:UIControlEventValueChanged];
		cell.accessoryView = toggle;
		break;
	}
	case OPSectionLevel: {
		cell.textLabel.text = @"Same volume for every song";
		cell.selectionStyle = UITableViewCellSelectionStyleNone;
		UISwitch *toggle = [UISwitch new];
		toggle.on = OPMusicSettings.levelVolume;
		toggle.onTintColor = self.accentColor;
		[toggle addTarget:self action:@selector(levelToggled:) forControlEvents:UIControlEventValueChanged];
		cell.accessoryView = toggle;
		break;
	}
	case OPSectionCache: {
		cell.textLabel.text = @"Cache the next song";
		cell.selectionStyle = UITableViewCellSelectionStyleNone;
		UISwitch *toggle = [UISwitch new];
		toggle.on = OPMusicSettings.cacheNext;
		toggle.onTintColor = self.accentColor;
		[toggle addTarget:self action:@selector(cacheToggled:) forControlEvents:UIControlEventValueChanged];
		cell.accessoryView = toggle;
		break;
	}
	case OPSectionAmount: {
		NSTimeInterval seconds = OPMusicSettings.cacheChoices[indexPath.row].doubleValue;
		cell.textLabel.text = [OPMusicSettings titleForCacheSeconds:seconds];
		cell.accessoryType =
		    seconds == OPMusicSettings.cacheSeconds ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
		break;
	}
	case OPSectionCrossfade: {
		NSTimeInterval seconds = OPMusicSettings.crossfadeChoices[indexPath.row].doubleValue;
		cell.textLabel.text = seconds > 0 ? [NSString stringWithFormat:@"%.0f seconds", seconds] : @"Off";
		cell.accessoryType = seconds == OPMusicSettings.crossfadeSeconds ? UITableViewCellAccessoryCheckmark
		                                                                  : UITableViewCellAccessoryNone;
		break;
	}
	case OPSectionDisk: {
		NSInteger megabytes = OPMusicSettings.diskCacheChoices[indexPath.row].integerValue;
		cell.textLabel.text = [OPMusicSettings titleForDiskCacheMegabytes:megabytes];
		cell.accessoryType = megabytes == OPMusicSettings.diskCacheMegabytes ? UITableViewCellAccessoryCheckmark
		                                                                     : UITableViewCellAccessoryNone;
		break;
	}
	case OPSectionAfter: {
		cell.textLabel.text = @"YouTube Music's recommendations";
		cell.selectionStyle = UITableViewCellSelectionStyleNone;
		UISwitch *toggle = [UISwitch new];
		toggle.on = OPMusicSettings.accountRecommendations && OPMusicWebAccount.signedIn;
		toggle.enabled = OPMusicWebAccount.signedIn;
		toggle.onTintColor = self.accentColor;
		[toggle addTarget:self
		              action:@selector(recommendationsToggled:)
		    forControlEvents:UIControlEventValueChanged];
		cell.accessoryView = toggle;
		if (!OPMusicWebAccount.signedIn)
			cell.textLabel.textColor = self.secondaryTextColor;
		break;
	}
	case OPSectionAccount:
		if (OPMusicWebAccount.signedIn) {
			cell.textLabel.text = @"Sign out of YouTube Music";
			cell.textLabel.textColor = UIColor.systemRedColor;
		} else {
			cell.textLabel.text = @"Sign in to YouTube Music";
			cell.textLabel.textColor = self.accentColor;
		}
		break;
	default:
		cell.textLabel.text = @"App settings";
		cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
		break;
	}
	return cell;
}

- (void)recommendationsToggled:(UISwitch *)toggle {
	OPMusicSettings.accountRecommendations = toggle.on;
}

- (void)songsToggled:(UISwitch *)toggle {
	OPMusicSettings.songVersions = toggle.on;
}

- (void)titlesToggled:(UISwitch *)toggle {
	OPMusicSettings.originalTitles = toggle.on;
}

- (void)levelToggled:(UISwitch *)toggle {
	OPMusicSettings.levelVolume = toggle.on;
}

- (void)searchToggled:(UISwitch *)toggle {
	OPMusicSettings.searchAsYouType = toggle.on;
}

- (void)cacheToggled:(UISwitch *)toggle {
	OPMusicSettings.cacheNext = toggle.on;
	[self.tableView reloadSections:[NSIndexSet indexSetWithIndex:OPSectionAmount]
	              withRowAnimation:UITableViewRowAnimationAutomatic];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	if (indexPath.section == OPSectionAmount) {
		OPMusicSettings.cacheSeconds = OPMusicSettings.cacheChoices[indexPath.row].doubleValue;
		[tableView reloadSections:[NSIndexSet indexSetWithIndex:OPSectionAmount]
		         withRowAnimation:UITableViewRowAnimationNone];
	} else if (indexPath.section == OPSectionCrossfade) {
		OPMusicSettings.crossfadeSeconds = OPMusicSettings.crossfadeChoices[indexPath.row].doubleValue;
		[tableView reloadSections:[NSIndexSet indexSetWithIndex:OPSectionCrossfade]
		         withRowAnimation:UITableViewRowAnimationNone];
	} else if (indexPath.section == OPSectionDisk) {
		OPMusicSettings.diskCacheMegabytes = OPMusicSettings.diskCacheChoices[indexPath.row].integerValue;
		[tableView reloadSections:[NSIndexSet indexSetWithIndex:OPSectionDisk]
		         withRowAnimation:UITableViewRowAnimationNone];
	} else if (indexPath.section == OPSectionAccount) {
		[self accountTapped];
	} else if (indexPath.section == OPSectionApp && self.onAppSettings) {
		self.onAppSettings();
	}
}

- (void)accountTapped {
	if (!OPMusicWebAccount.signedIn) {
		OPMusicWebSignInViewController *signIn = [OPMusicWebSignInViewController new];
		signIn.backgroundColor = self.backgroundColor;
		[self.navigationController pushViewController:signIn animated:YES];
		return;
	}
	UIAlertController *alert =
	    [UIAlertController alertControllerWithTitle:@"Sign out of YouTube Music?"
	                                        message:@"The app's own sign-in stays; Home goes back to the public shelves."
	                                 preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
	[alert addAction:[UIAlertAction actionWithTitle:@"Sign out"
	                                          style:UIAlertActionStyleDestructive
	                                        handler:^(UIAlertAction *action) {
		                                        [OPMusicWebAccount signOut];
	                                        }]];
	[self presentViewController:alert animated:YES completion:nil];
}

@end
