// The redesign's Albums & artists page: Apple Music's animated covers on album pages and its logos on
// artist pages, whether their downloads run in Low Data Mode, and what the redesign takes off both pages.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Shared/AnimatedArtwork/AnimatedArtwork.h"
#import "Redesigned/Artist/Artist.h"
#import "Album.h"

UIViewController *SGRAlbumSettingsPage(void) {
    return [[SGModPage alloc] initWithTitle:@"Albums & artists" intro:SGRestartNote sections:@[
        SGNotedSection(@"Apple Music", @[
            SGSwitchRow(@"Animated covers", @"At the top of an album that has one, about 5 MB each", SGRKeyAlbumMotion),
            SGSwitchRow(@"Artist logos", @"In place of the name on an artist's page", SGRKeyArtistLogo),
            SGOptionRow(@"Download in Low Data Mode", nil, SGKeyMotionLowData),
        ], @"Only the album's or artist's name is sent to Apple Music."),
        SGNotedSection(@"Hide under an album's tracks", @[
            SGSwitchRow(@"More by the artist", nil, SGRKeyAlbumHideMoreBy),
            SGSwitchRow(@"Related music videos", nil, SGRKeyAlbumHideVideos),
            SGSwitchRow(@"Concerts", nil, SGRKeyAlbumHideConcerts),
            SGSwitchRow(@"Merch", nil, SGRKeyAlbumHideMerch),
            SGSwitchRow(@"You might also like", nil, SGRKeyAlbumHideYouMightLike),
            SGSwitchRow(@"Everything else", @"Any other section Spotify sends", SGRKeyAlbumHideOther),
        ], @"Sections are told apart by their English names. With Spotify in another language, Everything else "
           @"covers them all."),
        SGSection(@"Hide on an artist's page", @[
            SGSwitchRow(@"Videos", @"In the Music list, and in the Video tab", SGRKeyArtistHideVideos),
            SGSwitchRow(@"Music, Video and Merch tabs", @"Without them the Music list is the page", SGRKeyArtistHideTabs),
        ]),
    ] footer:nil];
}
