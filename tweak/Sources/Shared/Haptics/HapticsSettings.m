// The Vibrations sections of the Player page, under either look (App/Pages.m puts them there): a card
// per kind, the way the Audio effects page has one per effect. Controls is a switch that opens out into its
// strength. Music Haptics is a choice of which plays, None, Generated or Native iOS, since the two never play
// at once: Generated opens out into its strength and what it follows (a choice that also says whether the
// rumble plays, rather than a switch of its own that one choice would leave with nothing to do), Native
// into what iOS's own is doing.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Haptics.h"

static NSString *const kMusicHapticsInfo = @"Generated: the iPhone taps along with the drums and rumbles under the bass of whatever Spotify is playing, worked out from the sound as it plays. It follows the sound this iPhone plays while Spotify is open: iOS plays no haptics for an app in the background, and a song playing on another device through Connect has no sound here to follow.\n\nNative iOS: iOS plays Apple Music's own haptic track for the song, in the background and on the lock screen too, for songs Apple Music has one for. It needs iOS 18 and Music Haptics on in Settings > Accessibility, and stays quiet for podcasts and songs Apple has none for.\n\nNone: no Music Haptics. Controls is separate.";

NSNotificationName const SGMusicHapticsModeChangedNotification = @"SGMusicHapticsModeChangedNotification";

static NSString *sg_status;

NSString *SGMusicHapticsStatus(void) {
    return sg_status ?: @"Waiting";
}

void SGSetMusicHapticsStatus(NSString *status) {
    sg_status = [status copy];
}

static BOOL nativeAvailable(void) {
    if (@available(iOS 18.0, *)) return YES;
    return NO;
}

SGMusicHapticsMode SGMusicHapticsModeNow(void) {
    NSInteger mode = SGInt(SGKeyMusicHapticsMode, -1);
    if (mode < SGMusicHapticsOff || mode > SGMusicHapticsNative) mode = SGFlag(SGKeyMusicHaptics, NO) ? SGMusicHapticsGenerated : SGMusicHapticsOff;
    if (mode == SGMusicHapticsNative && !nativeAvailable()) mode = SGMusicHapticsOff;
    return (SGMusicHapticsMode)mode;
}

// In SGMusicHapticsMode's order, Native iOS left out where iOS has none.
static NSArray<NSString *> *modeNames(void) {
    NSArray<NSString *> *names = @[@"None", @"Generated", @"Native iOS"];
    return nativeAvailable() ? names : [names subarrayWithRange:NSMakeRange(0, 2)];
}

static NSArray<NSString *> *modeNotes(void) {
    return @[@"No Music Haptics",
             @"The mod's own, from the sound, while Spotify is open",
             @"Apple Music's haptic track, in the background too"];
}

static NSArray<NSString *> *followsNames(void) {
    return @[@"Everything", @"Beat", @"Bass"];
}

static NSArray<NSString *> *followsNotes(void) {
    return @[@"A tap on each kick and snare, and a rumble under the bass",
             @"A tap on each kick and snare, no rumble",
             @"A tap on each kick, and a rumble under the bass"];
}

static void strengthRange(NSString *key, NSInteger *minimum, NSInteger *maximum) {
    BOOL music = [key isEqualToString:SGKeyMusicStrength];
    *minimum = music ? SGMusicStrengthMin : SGControlStrengthMin;
    *maximum = music ? SGMusicStrengthMax : SGControlStrengthMax;
}

double SGHapticsStrength(NSString *key) {
    NSInteger minimum, maximum;
    strengthRange(key, &minimum, &maximum);
    return MAX(minimum, MIN(maximum, SGInt(key, 100))) / 100.0;
}

SGMusicFollows SGMusicHapticsFollows(void) {
    NSInteger follows = SGInt(SGKeyMusicFollows, SGMusicFollowsEverything);
    return follows >= SGMusicFollowsEverything && follows <= SGMusicFollowsBass ? (SGMusicFollows)follows : SGMusicFollowsEverything;
}

// A percentage slider over a strength key, telling `changed` each step it stores.
static SGModRow *strengthRow(NSString *key, void (^changed)(void)) {
    NSInteger minimum, maximum;
    strengthRange(key, &minimum, &maximum);
    return SGSliderRow(@"Strength", nil, minimum, maximum, SGStrengthStep,
        ^double { return SGHapticsStrength(key) * 100; },
        ^(double value) {
            SGSetInt(key, lround(value));
            if (changed) changed();
        },
        ^NSString *(double value) { return [NSString stringWithFormat:@"%ld%%", lround(value)]; });
}

NSArray<SGModSection *> *SGVibrationsSections(void) {
    SGModRow *controls = SGSwitchRow(@"Controls", nil, SGKeyControlHaptics);
    SGModRow *controlStrength = strengthRow(SGKeyControlStrength, ^{
        // Felt as it is set: a tap at the new strength with each step.
        SGPlayFeedback(SGFeedbackAdd);
    });
    controlStrength.visible = ^BOOL { return SGEnabled(SGKeyControlHaptics); };

    // The list reads the stored index, so someone with none stored gets the one picked for them.
    if (SGInt(SGKeyMusicHapticsMode, -1) < 0) SGSetInt(SGKeyMusicHapticsMode, SGMusicHapticsModeNow());
    SGModRow *music = SGChoiceRow(@"Music Haptics", nil, SGKeyMusicHapticsMode, modeNames(), SGMusicHapticsOff);
    music.info = kMusicHapticsInfo;
    music.choiceNotes = modeNotes();
    music.chosen = ^(NSInteger index) {
        [NSNotificationCenter.defaultCenter postNotificationName:SGMusicHapticsModeChangedNotification object:nil];
    };
    BOOL (^generated)(void) = ^BOOL { return SGMusicHapticsModeNow() == SGMusicHapticsGenerated; };
    SGModRow *musicStrength = strengthRow(SGKeyMusicStrength, ^{ SGMusicHapticsSettingsChanged(); });
    musicStrength.visible = generated;
    SGModRow *follows = SGChoiceRow(@"Follows", nil, SGKeyMusicFollows, followsNames(), SGMusicFollowsEverything);
    follows.choiceNotes = followsNotes();
    follows.chosen = ^(NSInteger index) { SGMusicHapticsSettingsChanged(); };
    follows.visible = generated;
    SGModRow *status = SGStatRow(@"Status", ^NSString *{ return SGMusicHapticsStatus(); });
    status.visible = ^BOOL { return SGMusicHapticsModeNow() == SGMusicHapticsNative; };

    return @[
        SGSection(@"Vibrations", @[SGWithSymbol(controls, @"hand.tap"), controlStrength]),
        SGSection(nil, @[SGWithSymbol(music, @"waveform"), musicStrength, follows, status]),
    ];
}
