// One font for the whole app (Fonts.x), chosen on the Appearance card under either look.
#import <UIKit/UIKit.h>

#define SGKeyAppFont @"spotifyglass.font"

typedef NS_ENUM(NSInteger, SGAppFont) {
    SGAppFontSpotify,   // Spotify's own, untouched
    SGAppFontSystem,    // San Francisco
    SGAppFontRounded,   // SF Rounded
    SGAppFontSerif,     // New York
    SGAppFontMono,      // SF Mono
};

SGAppFont SGAppFontChosen(void);
NSArray<NSString *> *SGAppFontNames(void);
