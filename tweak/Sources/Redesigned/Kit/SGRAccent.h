// The redesign's accent colour in place of Spotify's green (SGRAccent.x), chosen apart from the native
// look's and stored under its own key; unset is #37F200, negative keeps Spotify's own green.
#import <UIKit/UIKit.h>

#define SGRKeyAccent @"spotifyglass.redesign.accent"   // 0xRRGGBB
// The last colour picked, kept while a preset is in place so Custom brings it back.
#define SGRKeyAccentCustom @"spotifyglass.redesign.accent.custom"
// The redesign's own green until another is picked; Spotify's is a pick of its own, stored as -1.
#define SGRDefaultAccent 0x37F200

UIColor *SGRAccentColor(void);   // nil while Spotify's own green is kept
NSInteger SGRAccentRGB(void);    // the colour in effect, 0xRRGGBB, Spotify's green included

@class SGModRow;
NSArray<SGModRow *> *SGRAppearanceRows(void);   // the accent colour, for the Appearance page
