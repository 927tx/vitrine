// The redesign's Albums & artists page: Apple Music's animated covers on album pages and its logos on
// artist pages, and whether their downloads run in Low Data Mode.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Shared/AnimatedArtwork/AnimatedArtwork.h"
#import "Album.h"

UIViewController *SGRAlbumSettingsPage(void) {
    return [[SGModPage alloc] initWithTitle:@"Albums & artists" intro:SGRestartNote sections:@[
        SGNotedSection(@"Apple Music", @[
            SGSwitchRow(@"Animated covers", @"At the top of an album that has one, about 5 MB each", SGRKeyAlbumMotion),
            SGSwitchRow(@"Artist logos", @"In place of the name on an artist's page", SGRKeyArtistLogo),
            SGOptionRow(@"Download in Low Data Mode", nil, SGKeyMotionLowData),
        ], @"Only the album's or artist's name is sent to Apple Music."),
    ] footer:nil];
}
