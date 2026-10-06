// What the harness does not compile: the accent hook (SGRAccent.x), the repaint hook (SGRRepaint.x), the
// tab bar's composition (Navbar.x) and Mod Settings. Spotify's order of tabs stays as the mock has it.
#import <UIKit/UIKit.h>

UIColor *SGRAccentColor(void) { return nil; }
__weak UIView *sgr_nowPlayingRoot = nil;
NSHashTable<UIView *> *sgr_nowPlayingPainted = nil;
__weak UIView *sgr_lyricsPageRoot = nil;
__weak UIView *sgr_playlistRoot = nil;
__weak UIView *sgr_albumRoot = nil;
__weak UIView *sgr_artistRoot = nil;

void SGRComposeTabBar(UIView *tabBar) {}

// With `split` among the launch words, Search is a split tab, which TabBar.x stands on a bar of its own.
BOOL SGRTabIsApart(UIView *item) {
    if (![NSProcessInfo.processInfo.arguments containsObject:@"split"]) return NO;
    for (UIView *sub in item.subviews) {
        if ([sub isKindOfClass:UILabel.class] && [((UILabel *)sub).text isEqualToString:@"Search"]) return YES;
    }
    return NO;
}
void SGRLogTabBarRow(UIView *tabBar) {}
// The tab of the mod's own whose page is up (Navbar.x), which the `lit` launch word sets by hand.
__weak UIView *sgHarnessLitTab = nil;
UIView *SGRNavbarLitTab(void) { return sgHarnessLitTab; }
void SGRNavbarForgetTab(void) {
    if (sgHarnessLitTab) NSLog(@"[harness] the lit tab forgotten");
    sgHarnessLitTab = nil;
}
void SGOpenModSettings(UIView *source) {}
// Shared/Player/PlayerEvents.x, which TabBarMinimize.x listens to.
NSString *const SGPlayerTransitionNotification = @"spotifyglass.playerTransition";
