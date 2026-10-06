// The redesign's navbar: the glass tab bar (TabBar.x) over Spotify's own, composed from its own list
// (Navbar.x, NavbarLayout.m), which the redesign keeps apart from the native look's: an ordered list of
// entries, each a dictionary. An entry with a URI is a tab of the mod's own; one without names
// one of Spotify's, by the label under its icon. No list at all is Spotify's order, all shown.
#import <UIKit/UIKit.h>

#define SGRKeyNavbar @"spotifyglass.redesign.navbar"
// Icons only on the glass bar. Off unless set; applies as soon as the bar lays out again.
#define SGRKeyNavbarHideLabels @"spotifyglass.redesign.navbar.hideLabels"

extern NSString *const SGRNavbarID;      // NSString, the entry's identity
extern NSString *const SGRNavbarTitle;   // NSString, the name in the settings list and under the icon
extern NSString *const SGRNavbarURI;     // NSString, the mod's own tabs only: what a tap opens
extern NSString *const SGRNavbarIcon;    // NSString, an SPTEncoreIcon class method such as "podcasts", or an SF Symbol
extern NSString *const SGRNavbarIconSet; // NSString, SGTabIconSetSymbols when the icon is an SF Symbol; none is Encore
extern NSString *const SGRNavbarHidden;  // NSNumber
NSArray<NSDictionary *> *SGRNavbarLayout(void);
void SGRSetNavbarLayout(NSArray<NSDictionary *> *layout);
// The tabs set apart at the trailing end of the bar (Split tabs), by their entries' identities.
NSArray<NSString *> *SGRNavbarSplit(void);
void SGRSetNavbarSplit(NSArray<NSString *> *split);
// Spotify's own tabs in Spotify's order, as Navbar.x last saw them on the bar.
NSArray<NSString *> *SGRNavbarStock(void);
void SGRSetNavbarStock(NSArray<NSString *> *stock);
// What a tab of the mod's own opens: its URI as typed or pasted, share links made spotify: URIs, and
// the URIs of presets that never opened (spotify:collection:playlists, up to 0.20) moved to the ones
// that replaced them, so a tab saved back then works without being added again.
NSURL *SGRNavbarTabURL(NSString *uri);

// Navbar.x, called from the tab bar's layout passes in TabBar.x.
void SGRComposeTabBar(UIView *tabBar);
void SGRLogTabBarRow(UIView *tabBar);
// Lays the bar out again after the Navbar page changes something, so it does not wait for a touch.
void SGRRefreshTabBar(void);
// Whether a tab of the composed row is one of the split tabs at its trailing end, for TabBar.x's second bar.
BOOL SGRTabIsApart(UIView *item);

// The glass bar minimizes as a page scrolls down (TabBarMinimize.x): it shrinks to two of its tabs, the
// now playing card coming down between them. On unless switched off; read as each scroll goes.
#define SGRKeyNavbarMinimize @"spotifyglass.redesign.navbar.minimize"
BOOL SGRTabBarMinimized(void);
// TabBar.x lays both bars out for it, the now playing bar in the same animation; `animated` NO is a cut.
void SGRSetTabBarMinimized(BOOL minimized, BOOL animated);
// The room between the minimized bar's two tabs, `height` high and centred on them, in `host`'s
// coordinates: where the now playing card goes. CGRectNull while the bar is not minimized or not on screen.
CGRect SGRTabBarInlineSlot(UIView *host, CGFloat height);

UIViewController *SGRNavbarSettingsPage(void);   // the tab editor, in Mod Settings
UIViewController *SGRNavbarEditorPage(void);     // the tab editor alone, for the welcome tour
