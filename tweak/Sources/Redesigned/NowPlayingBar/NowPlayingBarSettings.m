// The now playing bar's rows of the redesign, on the Player page under its showcase
// (Redesigned/Player/PlayerSettings.m puts them there).
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "NowPlayingBar.h"

NSArray<SGModRow *> *SGRNowPlayingBarRows(void) {
    return @[
        SGHideRow(@"Hide the device button", @"On the now playing bar", SGRHideBarConnect),
    ];
}
