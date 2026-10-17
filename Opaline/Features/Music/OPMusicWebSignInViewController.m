#import "OPMusicWebSignInViewController.h"
#import "../../Core/Music/OPMusicWebAccount.h"
@import WebKit;

/// What music.youtube.com's own "Sign in" opens: Google's login, then
/// YouTube's handoff that sets the .youtube.com cookies, then back home.
static NSString *const OPSignInURL =
    @"https://accounts.google.com/ServiceLogin?service=youtube&passive=true&continue="
    @"https%3A%2F%2Fwww.youtube.com%2Fsignin%3Faction_handle_signin%3Dtrue%26app%3Ddesktop%26next%3D"
    @"https%253A%252F%252Fmusic.youtube.com%252F";

@interface OPMusicWebSignInViewController () <WKNavigationDelegate, WKHTTPCookieStoreObserver>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) UIProgressView *progress;
@property (nonatomic) BOOL finished;
@property (nonatomic) NSUInteger skippedInterstitials;
@end

@implementation OPMusicWebSignInViewController

- (instancetype)init {
	if ((self = [super initWithNibName:nil bundle:nil])) {
		_backgroundColor = UIColor.systemBackgroundColor;
		self.title = @"YouTube Music sign-in";
	}
	return self;
}

/// Google refuses sign-in from an embedded web view, which it tells by the
/// user agent (WKWebView's lacks "Version/… Safari/…"); Safari's own string
/// for this system passes.
+ (NSString *)safariUserAgent {
	NSString *os = [UIDevice.currentDevice.systemVersion stringByReplacingOccurrencesOfString:@"." withString:@"_"];
	NSArray *parts = [UIDevice.currentDevice.systemVersion componentsSeparatedByString:@"."];
	NSString *version = [NSString stringWithFormat:@"%@.0", parts.firstObject ?: @"14"];
	return [NSString stringWithFormat:@"Mozilla/5.0 (iPhone; CPU iPhone OS %@ like Mac OS X) AppleWebKit/605.1.15 "
	                                  @"(KHTML, like Gecko) Version/%@ Mobile/15E148 Safari/604.1",
	                                  os, version];
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.view.backgroundColor = self.backgroundColor;
	self.navigationItem.leftBarButtonItem =
	    [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
	                                                  target:self
	                                                  action:@selector(cancel)];

	WKWebViewConfiguration *config = [WKWebViewConfiguration new];
	config.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];
	self.webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:config];
	self.webView.customUserAgent = [OPMusicWebSignInViewController safariUserAgent];
	self.webView.navigationDelegate = self;
	self.webView.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:self.webView];

	self.progress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleBar];
	self.progress.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:self.progress];

	UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
	[NSLayoutConstraint activateConstraints:@[
		[self.webView.topAnchor constraintEqualToAnchor:safe.topAnchor],
		[self.webView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
		[self.webView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
		[self.webView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
		[self.progress.topAnchor constraintEqualToAnchor:safe.topAnchor],
		[self.progress.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
		[self.progress.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
	]];
	[self.webView addObserver:self forKeyPath:@"estimatedProgress" options:0 context:NULL];
	[config.websiteDataStore.httpCookieStore addObserver:self];
	[self.webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:OPSignInURL]]];
	[OPMusicWebAccount log:@"web account: sign-in opened"];
}

- (void)dealloc {
	[_webView removeObserver:self forKeyPath:@"estimatedProgress"];
	[_webView.configuration.websiteDataStore.httpCookieStore removeObserver:self];
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
	double value = self.webView.estimatedProgress;
	[self.progress setProgress:(float)value animated:YES];
	self.progress.hidden = value >= 1;
}

- (void)cancel {
	[OPMusicWebAccount log:@"web account: sign-in cancelled"];
	[self closeSignedIn:NO];
}

- (void)closeSignedIn:(BOOL)signedIn {
	if (self.finished)
		return;
	self.finished = YES;
	void (^completion)(BOOL) = self.completion;
	void (^done)(void) = ^{
		if (completion)
			completion(signedIn);
	};
	// Pushed from settings, or presented on its own.
	UINavigationController *nav = self.navigationController;
	if (nav && nav.viewControllers.firstObject != self) {
		[nav popViewControllerAnimated:YES];
		done();
	} else {
		[self dismissViewControllerAnimated:YES completion:done];
	}
}

#pragma mark - WKNavigationDelegate

/// Pages are only logged: YouTube Music's own page may never finish (or
/// render) on this WebKit, so the session is caught in the cookie store.
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
	NSString *host = webView.URL.host ?: @"";
	[OPMusicWebAccount log:[NSString stringWithFormat:@"web account: page %@%@", host, webView.URL.path ?: @""]];
	[self checkCookies];
}

#pragma mark - WKHTTPCookieStoreObserver

/// The session is complete once YouTube's sign-in handoff has set SAPISID
/// on .youtube.com — before music.youtube.com loads, so the flow does not
/// depend on that page working here. (Google's login sets one on
/// .google.com first, which does not count.)
- (void)cookiesDidChangeInCookieStore:(WKHTTPCookieStore *)cookieStore {
	[self checkCookies];
}

- (void)checkCookies {
	if (self.finished)
		return;
	__weak typeof(self) weakSelf = self;
	[self.webView.configuration.websiteDataStore.httpCookieStore getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
		typeof(self) strongSelf = weakSelf;
		if (!strongSelf || strongSelf.finished)
			return;
		NSUInteger found = [cookies indexOfObjectPassingTest:^BOOL(NSHTTPCookie *cookie, NSUInteger i, BOOL *stop) {
			return [cookie.name isEqualToString:@"SAPISID"] && [cookie.domain hasSuffix:@"youtube.com"];
		}];
		if (found != NSNotFound && [OPMusicWebAccount saveCookies:cookies])
			[strongSelf closeSignedIn:YES];
	}];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
	[OPMusicWebAccount log:[NSString stringWithFormat:@"web account: page failed: %@", error.localizedDescription]];
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
	[OPMusicWebAccount log:@"web account: web page crashed"];
}

- (void)webView:(WKWebView *)webView
    didFailProvisionalNavigation:(WKNavigation *)navigation
                       withError:(NSError *)error {
	[OPMusicWebAccount log:[NSString stringWithFormat:@"web account: load failed: %@", error.localizedDescription]];
}

/// The YouTube app's universal links must not hijack the flow: Allow + 2
/// is WebKit's private "allow without trying app link".
- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationAction:(WKNavigationAction *)action
                    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
	NSString *scheme = action.request.URL.scheme.lowercaseString ?: @"";
	BOOL web = [scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"] ||
	           [scheme isEqualToString:@"about"] || [scheme isEqualToString:@"blob"] ||
	           [scheme isEqualToString:@"data"];
	NSURL *skip = web ? [self pastInterstitial:action.request.URL] : nil;
	if (skip) {
		decisionHandler(WKNavigationActionPolicyCancel);
		[webView loadRequest:[NSURLRequest requestWithURL:skip]];
		return;
	}
	decisionHandler(web ? WKNavigationActionPolicyAllow + 2 : WKNavigationActionPolicyCancel);
}

/// Where to go instead of one of Google's after-login pages ("add a
/// recovery phone", passkeys — gds.google.com, myaccount.google.com): the
/// sign-in is already done by then, and those pages render blank on this
/// WebKit. Their `continue`, else the sign-in URL again, which a signed-in
/// session passes straight through to YouTube's handoff. A few times at
/// most, so a page that keeps coming back cannot loop.
- (NSURL *)pastInterstitial:(NSURL *)url {
	NSString *host = url.host.lowercaseString ?: @"";
	if (!([host isEqualToString:@"gds.google.com"] || [host isEqualToString:@"myaccount.google.com"]) ||
	    self.skippedInterstitials >= 3)
		return nil;
	self.skippedInterstitials++;
	NSURL *next = [NSURL URLWithString:OPSignInURL];
	for (NSURLQueryItem *item in [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO].queryItems) {
		NSURL *target = [item.name isEqualToString:@"continue"] ? [NSURL URLWithString:item.value ?: @""] : nil;
		if ([target.scheme isEqualToString:@"https"])
			next = target;
	}
	[OPMusicWebAccount log:[NSString stringWithFormat:@"web account: skipping %@%@ → %@%@", host, url.path, next.host, next.path]];
	return next;
}

@end
