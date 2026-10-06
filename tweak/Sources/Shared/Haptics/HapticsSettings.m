// The Vibrations page, under either look (App/Pages.m links it from the Player page): the preview at the
// top (SGVibrationsPreview.m), then a card per kind, the way the Audio effects page has one per effect.
// Controls is a switch that opens out into its strength. Music Haptics is a choice of which plays, None,
// Generated or Native iOS, since the two never play at once: Generated opens out into its strength and what
// it follows (a choice that also says whether the rumble plays, rather than a switch of its own that one
// choice would leave with nothing to do), Native into what iOS's own is doing. Each strength's slider plays
// a tap at the new strength with each step, and the preview ripples with it.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Haptics.h"
#import "SGVibrationsPreview.h"

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

// The cards, `preview` told when something it reads out changes and shown the slider's taps.
static NSArray<SGModSection *> *sections(SGVibrationsPreview *preview) {
    __weak SGVibrationsPreview *weakPreview = preview;
    SGModRow *controls = SGSwitchRow(@"Controls", nil, SGKeyControlHaptics);
    controls.changed = ^(BOOL on) { [weakPreview reload]; };
    SGModRow *controlStrength = strengthRow(SGKeyControlStrength, ^{
        // Felt as it is set, and seen: a tap at the new strength with each step, and its ripple.
        SGPlayFeedback(SGFeedbackAdd);
        [weakPreview rippleAt:SGHapticsStrength(SGKeyControlStrength)];
    });
    controlStrength.waitsOn = SGKeyControlHaptics;

    // The list reads the stored index, so someone with none stored gets the one picked for them.
    if (SGInt(SGKeyMusicHapticsMode, -1) < 0) SGSetInt(SGKeyMusicHapticsMode, SGMusicHapticsModeNow());
    SGModRow *music = SGChoiceRow(@"Music Haptics", nil, SGKeyMusicHapticsMode, modeNames(), SGMusicHapticsOff);
    music.info = kMusicHapticsInfo;
    music.choiceNotes = modeNotes();
    music.chosen = ^(NSInteger index) {
        [NSNotificationCenter.defaultCenter postNotificationName:SGMusicHapticsModeChangedNotification object:nil];
        [weakPreview reload];
    };
    BOOL (^generated)(void) = ^BOOL { return SGMusicHapticsModeNow() == SGMusicHapticsGenerated; };
    SGModRow *musicStrength = strengthRow(SGKeyMusicStrength, ^{
        // As Controls' Strength: a kick at the new strength with each step, and its ripple.
        SGMusicHapticsSettingsChanged();
        SGMusicHapticsPreview();
        [weakPreview rippleAt:SGHapticsStrength(SGKeyMusicStrength) / 2];
    });
    musicStrength.visible = generated;
    SGModRow *follows = SGChoiceRow(@"Follows", nil, SGKeyMusicFollows, followsNames(), SGMusicFollowsEverything);
    follows.choiceNotes = followsNotes();
    follows.chosen = ^(NSInteger index) { SGMusicHapticsSettingsChanged(); };
    follows.visible = generated;
    SGModRow *status = SGStatRow(@"Status", ^NSString *{ return SGMusicHapticsStatus(); });
    status.visible = ^BOOL { return SGMusicHapticsModeNow() == SGMusicHapticsNative; };

    return @[
        SGSection(nil, @[SGWithSymbol(controls, @"hand.tap"), controlStrength]),
        SGSection(nil, @[SGWithSymbol(music, @"waveform"), musicStrength, follows, status]),
    ];
}

#pragma mark - the page

@interface SGVibrationsPage : SGModPage
@property (nonatomic, strong) SGVibrationsPreview *preview;
@end

@implementation SGVibrationsPage

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.tableHeaderView = self.preview;
}

// The header keeps the height it is given, so it is sized here and handed back to the table only when that
// changes (a table header set on every pass lays the table out again forever).
- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    UITableView *table = self.tableView;
    CGFloat width = table.bounds.size.width;
    self.preview.layoutMargins = UIEdgeInsetsMake(0, table.layoutMargins.left, 0, table.layoutMargins.right);
    CGSize size = CGSizeMake(width, [self.preview heightForWidth:width]);
    if (CGSizeEqualToSize(self.preview.bounds.size, size)) return;
    self.preview.frame = (CGRect){CGPointZero, size};
    table.tableHeaderView = self.preview;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.preview reload];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    self.preview.listening = YES;
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    self.preview.listening = NO;
}

@end

UIViewController *SGVibrationsSettingsPage(void) {
    SGVibrationsPreview *preview = [SGVibrationsPreview new];
    SGVibrationsPage *page = [[SGVibrationsPage alloc] initWithTitle:@"Vibrations" intro:nil sections:sections(preview) footer:nil];
    page.preview = preview;
    return page;
}

NSString *SGVibrationsSummary(void) {
    BOOL controls = SGEnabled(SGKeyControlHaptics), music = SGMusicHapticsModeNow() != SGMusicHapticsOff;
    if (controls && music) return @"On";
    return controls ? @"Controls" : music ? @"Music Haptics" : @"Off";
}
