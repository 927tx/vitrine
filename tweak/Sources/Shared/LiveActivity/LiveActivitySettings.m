// The Live Activity page (App/ModSettings.x links it from the root, under either look).
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Shared/Player/SleepTimer.h"
#import "LiveActivity.h"

static NSArray<NSString *> *viewNames(void) {
    return @[@"Lyrics", @"Queue", @"Control menu"];
}

UIViewController *SGLiveActivitySettingsPage(void) {
    SGModRow *on = SGOptionRow(@"Live Activity", nil, SGKeyLiveActivity);
    on.changed = ^(BOOL value) { SGSetLiveActivityEnabled(value); };
    SGModRow *view = SGChoiceRow(@"Shows", nil, SGKeyLiveActivityView, viewNames(), SGLiveActivityLyrics);
    // The lyrics view's own rows, shown while it is picked; the tick reads them, so they apply at once.
    SGModRow *translation = SGOptionRow(@"Translations", @"Under the line, when the lyrics have one", SGKeyLiveActivityTranslation);
    SGModRow *size = SGChoiceRow(@"Text size", nil, SGKeyLiveActivityTextSize, @[@"Small", @"Medium", @"Large"], SGLiveActivityTextMedium);
    for (SGModRow *row in @[translation, size]) row.visible = ^BOOL { return SGInt(SGKeyLiveActivityView, SGLiveActivityLyrics) == SGLiveActivityLyrics; };
    // The sleep timer's own: the card's Timer tab, the Sleep Timer shortcut and its control all fade by it, card on or off.
    NSArray<NSString *> *fades = SGSleepTimerFadeNames();
    SGModRow *fade = SGMenuRow(@"Fade out", fades, ^NSString *{ return fades[(NSUInteger)SGSleepTimerFadeChoice()]; },
                               ^(NSInteger index) { SGSetInt(SGKeySleepTimerFade, index); });
    return [[SGModPage alloc] initWithTitle:@"Live Activity" intro:nil sections:@[
        SGSection(nil, @[on, view, translation, size]),
        SGNotedSection(@"Sleep timer", @[fade],
                       @"How long the sound fades before the sleep timer pauses Spotify, from the Timer tab, the Sleep Timer shortcut or Control Center."),
    ] footer:nil];
}

NSString *SGLiveActivitySummary(void) {
    if (!SGFlag(SGKeyLiveActivity, NO)) return @"Off";
    NSInteger index = SGInt(SGKeyLiveActivityView, SGLiveActivityLyrics);
    NSArray<NSString *> *names = viewNames();
    return index >= 0 && index < (NSInteger)names.count ? names[index] : names.firstObject;
}
