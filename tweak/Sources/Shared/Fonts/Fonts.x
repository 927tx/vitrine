// One font for the whole app, under either look: Spotify's own (Circular and Spotify Mix, a file per
// script in SpotifyShared's Fonts.bundle), or the system's in one of its designs. Spotify asks for its
// fonts by name, so a name from its two families comes back as the system font at the same size, with
// the weight its name ends in. The rounded, serif and monospaced designs reach the system font too, so
// the mod's own text follows. Read at launch.
#import "Core/SGCore.h"
#import "Shared/Fonts/Fonts.h"

static SGAppFont sg_font;

static BOOL spotifys(NSString *name) {
    return [name hasPrefix:@"CircularSp"] || [name hasPrefix:@"SpotifyMix"] || [name hasPrefix:@"Circular"];
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

static UIFont *designed(UIFont *font) {
    if (sg_font < SGAppFontRounded || !font) return font;
    UIFontDescriptor *descriptor = [font.fontDescriptor fontDescriptorWithDesign:designOf(sg_font)];
    return descriptor ? [UIFont fontWithDescriptor:descriptor size:font.pointSize] : font;
}

static UIFont *systemFor(NSString *name, CGFloat size) {
    return designed([UIFont systemFontOfSize:size weight:weightOf(name)]);
}

%hook UIFont
+ (UIFont *)fontWithName:(NSString *)name size:(CGFloat)size {
    if (spotifys(name)) return systemFor(name, size);
    return %orig;
}

+ (UIFont *)fontWithDescriptor:(UIFontDescriptor *)descriptor size:(CGFloat)size {
    NSString *name = descriptor.fontAttributes[UIFontDescriptorNameAttribute] ?: descriptor.fontAttributes[UIFontDescriptorFamilyAttribute];
    if (spotifys(name)) return systemFor(name, size > 0 ? size : descriptor.pointSize);
    return %orig;
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
    return font >= SGAppFontSpotify && font <= SGAppFontMono ? font : SGAppFontSpotify;
}

NSArray<NSString *> *SGAppFontNames(void) {
    return @[@"Spotify", @"System", @"Rounded", @"Serif", @"Mono"];
}

%ctor {
    sg_font = SGAppFontChosen();
    if (sg_font == SGAppFontSpotify) return;
    %init;
    if (sg_font >= SGAppFontRounded) %init(Designs);
    SGLog(@"fonts: %@ in place of Spotify's", SGAppFontNames()[sg_font]);
}
