// One font for the whole app, under either look: Spotify's own (Circular and Spotify Mix, a file per
// script in SpotifyShared's Fonts.bundle), the system's in one of its designs, or a font file imported from
// Files (FontImport.m). Spotify asks for its fonts by name, so a name from its two families comes back as the
// system font at the same size, with the weight its name ends in. The rounded, serif and monospaced designs
// reach the system font too, so the mod's own text follows. An imported family and a family iOS carries
// take its place at the same size, each weight as the family's nearest face. Read at launch.
#import "Core/SGCore.h"
#import "Shared/Fonts/Fonts.h"

static SGAppFont sg_font;
static NSString *sg_family;   // the chosen family: one iOS carries, or the imported one once Core Text has it

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
    UIFont *font = spotifys(name) ? systemFor(name, size > 0 ? size : descriptor.pointSize) : nil;
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
