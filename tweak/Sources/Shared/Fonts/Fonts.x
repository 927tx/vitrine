// One font for the whole app, under either look: Spotify's own (Circular and Spotify Mix, a file per
// script in SpotifyShared's Fonts.bundle), the system's in one of its designs, or a font file imported from
// Files (FontImport.m). Spotify asks for its fonts by name, so a name from its two families comes back as the
// system font at the same size, with the weight its name ends in. The rounded, serif and monospaced designs
// reach the system font too, so the mod's own text follows. An imported family and a family iOS carries
// take its place at the same size, each weight as the family's nearest face. Read at launch.
#import <CoreText/CoreText.h>
#import "Core/SGCore.h"
#import "Shared/Fonts/Fonts.h"

static SGAppFont sg_font;
static NSString *sg_family;   // the chosen family: one iOS carries, or the imported one once Core Text has it

// A font name ("SpotifyMixUI-Bold") or family name ("Spotify Mix UI", which is how Spotify's text components ask) of
// Spotify's: the family name has spaces, and matching only the font name left most of the app in Spotify's font.
static BOOL spotifys(NSString *name) {
    NSString *joined = [name stringByReplacingOccurrencesOfString:@" " withString:@""];
    return [joined hasPrefix:@"CircularSp"] || [joined hasPrefix:@"SpotifyMix"] || [joined hasPrefix:@"Circular"];
}

// The weight a descriptor asks for: its traits', else its variable font's weight axis ('wght', 100 to 900), else
// none, for the name to say.
static NSNumber *weightAsked(UIFontDescriptor *descriptor) {
    NSDictionary *attributes = descriptor.fontAttributes;
    NSNumber *trait = attributes[UIFontDescriptorTraitsAttribute][UIFontWeightTrait];
    if ([trait isKindOfClass:NSNumber.class]) return trait;
    NSNumber *axis = attributes[(__bridge NSString *)kCTFontVariationAttribute][@(0x77676874)];   // 'wght'
    if (![axis isKindOfClass:NSNumber.class]) return nil;
    // CSS weights to UIFont's: 400 is regular (0), 700 bold (0.4), 900 black (0.62).
    double css = axis.doubleValue;
    return @(css <= 400 ? (css - 400) / 375 : css <= 700 ? (css - 400) / 750 : 0.4 + (css - 700) / 900);
}

// "CircularSp-Bold", "SpotifyMixUITitle-Arab-Extrabold": the weight is the last word.
static UIFontWeight weightOf(NSString *name) {
    NSString *last = [[name componentsSeparatedByString:@"-"].lastObject lowercaseString];
    if ([last containsString:@"black"] || [last containsString:@"extrabold"] || [last containsString:@"heavy"]) return UIFontWeightHeavy;
    if ([last containsString:@"bold"]) return UIFontWeightBold;
    if ([last containsString:@"medium"]) return UIFontWeightMedium;
    if ([last containsString:@"light"]) return UIFontWeightLight;
    return UIFontWeightRegular;
}

static UIFontDescriptorSystemDesign designOf(SGAppFont font) {
    switch (font) {
    case SGAppFontRounded: return UIFontDescriptorSystemDesignRounded;
    case SGAppFontSerif: return UIFontDescriptorSystemDesignSerif;
    case SGAppFontMono: return UIFontDescriptorSystemDesignMonospaced;
    default: return UIFontDescriptorSystemDesignDefault;
    }
}

// The family's upright face nearest the weight, so an italic file in the family never stands in for regular
// text. Its name is not Spotify's, so the descriptor hook passes it through.
static UIFont *family(CGFloat size, UIFontWeight weight) {
    UIFontDescriptor *descriptor = [UIFontDescriptor fontDescriptorWithFontAttributes:@{
        UIFontDescriptorFamilyAttribute: sg_family,
        UIFontDescriptorTraitsAttribute: @{UIFontWeightTrait: @(weight), UIFontSlantTrait: @0},
    }];
    return [UIFont fontWithDescriptor:descriptor size:size];
}

static UIFont *designed(UIFont *font) {
    if (sg_font < SGAppFontRounded || !font) return font;
    if (sg_font >= SGAppFontCustom) return family(font.pointSize, [font.fontDescriptor.fontAttributes[UIFontDescriptorTraitsAttribute][UIFontWeightTrait] doubleValue]) ?: font;
    UIFontDescriptor *descriptor = [font.fontDescriptor fontDescriptorWithDesign:designOf(sg_font)];
    return descriptor ? [UIFont fontWithDescriptor:descriptor size:font.pointSize] : font;
}

static UIFont *systemFor(NSString *name, CGFloat size) {
    if (sg_font >= SGAppFontCustom) return family(size, weightOf(name));
    return designed([UIFont systemFontOfSize:size weight:weightOf(name)]);
}

%hook UIFont
+ (UIFont *)fontWithName:(NSString *)name size:(CGFloat)size {
    UIFont *font = spotifys(name) ? systemFor(name, size) : nil;
    return font ?: %orig;
}

+ (UIFont *)fontWithDescriptor:(UIFontDescriptor *)descriptor size:(CGFloat)size {
    NSString *name = descriptor.fontAttributes[UIFontDescriptorNameAttribute] ?: descriptor.fontAttributes[UIFontDescriptorFamilyAttribute];
    if (!spotifys(name)) return %orig;
    CGFloat points = size > 0 ? size : descriptor.pointSize;
    NSNumber *weight = weightAsked(descriptor);
    UIFont *font = !weight ? systemFor(name, points)
        : sg_font >= SGAppFontCustom ? family(points, weight.doubleValue)
        : designed([UIFont systemFontOfSize:points weight:weight.doubleValue]);
    return font ?: %orig;
}
%end

%group Designs
%hook UIFont
+ (UIFont *)systemFontOfSize:(CGFloat)size weight:(UIFontWeight)weight {
    UIFont *font = %orig;
    return designed(font);
}

+ (UIFont *)systemFontOfSize:(CGFloat)size {
    UIFont *font = %orig;
    return designed(font);
}

+ (UIFont *)boldSystemFontOfSize:(CGFloat)size {
    UIFont *font = %orig;
    return designed(font);
}
%end
%end

SGAppFont SGAppFontChosen(void) {
    NSInteger font = SGInt(SGKeyAppFont, SGAppFontSpotify);
    return font >= SGAppFontSpotify && font <= SGAppFontFamily ? font : SGAppFontSpotify;
}

NSArray<NSString *> *SGAppFontNames(void) {
    return @[@"Default", @"San Francisco", @"SF Rounded", @"New York", @"SF Mono"];
}

NSArray<NSString *> *SGAppFontFamilies(void) {
    NSArray<NSString *> *all = @[@"Avenir Next", @"Helvetica Neue", @"Futura", @"Gill Sans", @"Optima", @"Georgia", @"Charter", @"Palatino", @"American Typewriter"];
    return [all filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *name, NSDictionary *bindings) {
        return [UIFont fontNamesForFamilyName:name].count > 0;
    }]];
}

%ctor {
    sg_font = SGAppFontChosen();
    if (sg_font == SGAppFontSpotify) return;
    // A process-wide registration ends with the process, so the file is registered again before any hook
    // runs. A file that is gone (a restored backup, a reinstall) leaves Spotify's font and keeps the choice,
    // so importing again is all it takes; Circular imported as a file of its own needs nothing done either.
    if (sg_font == SGAppFontCustom) {
        sg_family = SGRegisterCustomFont();
        if (!sg_family || spotifys(sg_family)) {
            SGLog(@"fonts: the imported font is not there, Spotify's stays");
            return;
        }
    }
    if (sg_font == SGAppFontFamily) {
        NSString *name = [NSUserDefaults.standardUserDefaults stringForKey:SGKeyAppFontFamily];
        if (![SGAppFontFamilies() containsObject:name]) {
            SGLog(@"fonts: the family %@ is not on this iPhone, Spotify's stays", name);
            return;
        }
        sg_family = name;
    }
    %init;
    if (sg_font >= SGAppFontRounded) %init(Designs);
    SGLog(@"fonts: %@ in place of Spotify's", sg_family ?: SGAppFontNames()[sg_font]);
}
