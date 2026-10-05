// The lock screen's moving artwork and whether it downloads in Low Data Mode. iOS 26 and up only.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "AnimatedArtwork.h"

NSArray *SGLockScreenMotionRows(void) {
    if (@available(iOS 26.0, *)) {
        return @[
            SGOptionRow(@"Moving artwork", @"The track's Canvas, else Apple Music's animated cover", SGKeyLockScreenMotion),
            SGOptionRow(@"Download in Low Data Mode", @"Up to about 7 MB a song", SGKeyMotionLowData),
        ];
    }
    return @[];
}
