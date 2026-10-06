// What the Logos files hold for the page: the accent colours as Accent.x and SGRAccent.x read them, and the
// font choice as Fonts.x reads it.
#import "Core/SGCore.h"
#import "Native/Appearance/Appearance.h"
#import "Redesigned/Kit/SGRAccent.h"
#import "Shared/Fonts/Fonts.h"

static NSInteger valid(NSInteger rgb) {
    return rgb >= 0 && rgb <= 0xFFFFFF ? rgb : -1;
}

UIColor *SGAccentColor(void) { return valid(SGInt(SGKeyAccent, -1)) < 0 ? nil : UIColor.redColor; }
NSInteger SGAccentRGB(void) { NSInteger rgb = valid(SGInt(SGKeyAccent, -1)); return rgb < 0 ? SGSpotifyGreen : rgb; }
UIColor *SGRAccentColor(void) { return valid(SGInt(SGRKeyAccent, SGRDefaultAccent)) < 0 ? nil : UIColor.redColor; }
NSInteger SGRAccentRGB(void) { NSInteger rgb = valid(SGInt(SGRKeyAccent, SGRDefaultAccent)); return rgb < 0 ? SGSpotifyGreen : rgb; }

SGAppFont SGAppFontChosen(void) {
    NSInteger font = SGInt(SGKeyAppFont, SGAppFontSpotify);
    return font >= SGAppFontSpotify && font <= SGAppFontCustom ? font : SGAppFontSpotify;
}

NSArray<NSString *> *SGAppFontNames(void) {
    return @[@"Spotify", @"System", @"Rounded", @"Serif", @"Mono", @"Custom font"];
}
