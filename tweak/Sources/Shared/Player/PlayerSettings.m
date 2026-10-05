// The player's settings that do not depend on the look: the lock screen widget's flags.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "PlayerSettings.h"
#import "Shared/AnimatedArtwork/AnimatedArtwork.h"

UIViewController *SGLockScreenWidgetPage(void) {
    NSArray *motion = SGLockScreenMotionRows();
    NSArray<SGModSection *> *mod = motion.count ? @[SGSection(@"Lock screen artwork", motion)] : @[];
    return [[SGModPage alloc] initWithTitle:@"Lock screen widget" intro:SGRestartNote sections:[mod arrayByAddingObjectsFromArray:@[
        SGSection(@"Controls", @[
            SGFlagRow(@"Like and dislike buttons", @"ios-feature-lockscreen.like_dislike_enabled"),
            SGFlagRow(@"Skip button on podcasts", @"ios-feature-lockscreen.skip_button_on_podcasts"),
            SGFlagRow(@"Chapter skip controls", @"ios-feature-lockscreen.enable_chapter_skip_controls"),
            SGFlagRow(@"Burst skip", @"ios-feature-lockscreen.burst_skip_enabled"),
        ]),
        SGSection(@"Artwork", @[
            SGFlagRow(@"Animated artwork", @"ios-feature-lockscreen.animated_artwork_enabled"),
            SGFlagRow(@"Video artwork", @"ios-feature-lockscreen.vit_artwork_enabled"),
            SGFlagRow(@"Companion content", @"ios-feature-lockscreen.companion_content_enabled"),
        ]),
    ]] footer:nil];
}
