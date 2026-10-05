// The Now playing page of the redesign, under Player (App/Pages.m puts it there): the bar and the
// player behind it.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "NowPlayingBar.h"
#import "Redesigned/Player/Player.h"
#import "Shared/AnimatedArtwork/AnimatedArtwork.h"

UIViewController *SGRNowPlayingBarSettingsPage(void) {
    return [[SGModPage alloc] initWithTitle:@"Now playing" intro:SGRestartNote sections:@[
        SGSection(nil, @[
            SGHideRow(@"Hide the device button", nil, SGRHideBarConnect),
        ]),
        SGSection(nil, @[
            SGChoiceRow(@"Background", @"Animated plays the Canvas or Apple Music's animated cover, over Fluid; the player's ⋯ menu switches between the two",
                        SGRKeyPlayerBackground, SGRPlayerBackgroundNames(), SGRPlayerBackground()),
            SGOptionRow(@"Download in Low Data Mode", @"Animated artwork, up to about 7 MB a song", SGKeyMotionLowData),
        ]),
    ] footer:nil];
}
