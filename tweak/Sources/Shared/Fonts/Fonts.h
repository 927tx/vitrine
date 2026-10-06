// One font for the whole app (Fonts.x), chosen on the Appearance page under either look, and a font file
// of the user's own as one of the choices (FontImport.m).
#import <UIKit/UIKit.h>

#define SGKeyAppFont @"spotifyglass.font"
// The imported font: its file's name in Application Support/Vitrine/Font, and the PostScript name read from it.
#define SGKeyAppFontFile @"spotifyglass.font.file"
#define SGKeyAppFontName @"spotifyglass.font.name"

typedef NS_ENUM(NSInteger, SGAppFont) {
    SGAppFontSpotify,   // Spotify's own, untouched
    SGAppFontSystem,    // San Francisco
    SGAppFontRounded,   // SF Rounded
    SGAppFontSerif,     // New York
    SGAppFontMono,      // SF Mono
    SGAppFontCustom,    // a .ttf or .otf imported from Files
};

SGAppFont SGAppFontChosen(void);
NSArray<NSString *> *SGAppFontNames(void);
// Registers the imported font with Core Text for this process and answers its PostScript name, or nil when
// there is no file or Core Text will not take it.
NSString *SGRegisterCustomFont(void);

@class SGModRow;
NSArray<SGModRow *> *SGAppFontRows(void);   // the Font choice and, while Custom font is chosen, the import
