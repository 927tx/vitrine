// Music Haptics' side of Haptics.h (MusicHaptics.x in the tweak), which the page calls as its choice and its
// settings change: each is logged with what the hooks would read at that moment.
#import "Core/SGCore.h"
#import "Shared/Haptics/Haptics.h"

__attribute__((constructor)) static void sg_logModeChanges(void) {
    [NSNotificationCenter.defaultCenter addObserverForName:SGMusicHapticsModeChangedNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        NSLog(@"[harness] Music Haptics plays %@", @[@"None", @"Generated", @"Native iOS"][SGMusicHapticsModeNow()]);
    }];
}

void SGMusicHapticsSettingsChanged(void) {
    NSLog(@"[harness] Music Haptics reads strength %.0f%%, follows %ld", SGHapticsStrength(SGKeyMusicStrength) * 100, (long)SGMusicHapticsFollows());
}
