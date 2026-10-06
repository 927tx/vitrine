// The player's settings that do not depend on the look: the lock screen widget's flags.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "PlayerSettings.h"
#import "Shared/AnimatedArtwork/AnimatedArtwork.h"

// Like and dislike is the one lock screen control a song gets. Spotify's flags for podcasts, audiobooks and its
// own lock screen artwork stay on the All flags page: the artwork section above is the mod's.
UIViewController *SGLockScreenWidgetPage(void) {
    NSArray *motion = SGLockScreenMotionRows();
    NSArray<SGModSection *> *mod = motion.count ? @[SGSection(@"Lock screen artwork", motion)] : @[];
    return [[SGModPage alloc] initWithTitle:@"Lock screen" intro:SGRestartNote sections:[mod arrayByAddingObjectsFromArray:@[
        SGSection(@"Controls", @[
            SGFlagRow(@"Like and dislike buttons", @"ios-feature-lockscreen.like_dislike_enabled"),
        ]),
    ]] footer:nil];
}
