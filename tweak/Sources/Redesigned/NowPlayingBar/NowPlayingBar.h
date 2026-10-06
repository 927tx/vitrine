// The redesign's now playing bar: the glass card it becomes (NowPlayingBar.x), Spotify's device button
// on that card hidden on request (BarConnect.x), glass behind the bar's and the tab bar's stand-ins while
// the player opens and closes (BarTransition.x), and the bar's rows in Mod Settings
// (NowPlayingBarSettings.m). The redesign keeps its own copy of the hide switch and its own key; the
// native look's lives in Native/NowPlayingBar/.
#import <UIKit/UIKit.h>

@class SGModRow;

#define SGRHideBarConnect @"spotifyglass.redesign.hide.barConnect"   // the device button on the card

// The bar's rows, on the Player page under its showcase (Redesigned/Player/PlayerSettings.m).
NSArray<SGModRow *> *SGRNowPlayingBarRows(void);

// The bar's glass card in `host`'s coordinates, with its corner radius; CGRectNull before the bar has
// been styled or while it is out of a window (NowPlayingBar.x). The bar keeps its geometry while
// Spotify hides it for the player's open and close.
CGRect SGRNowPlayingCardFrameIn(UIView *host, CGFloat *radius);
// The round artwork on that card in `host`'s coordinates; CGRectNull when none was found.
CGRect SGRNowPlayingArtworkFrameIn(UIView *host);
// Lays the bar out again at once, into the minimized tab bar's slot or back above the bar
// (Navbar.h's SGRTabBarInlineSlot); TabBar.x calls it inside its own animation.
void SGRNowPlayingBarFollowTabBar(void);
