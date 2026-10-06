// The Lyrics page's parts; App/Pages.m assembles the page.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Lyrics.h"
#import "Shared/LocalFiles/LocalLyrics.h"
#import "Shared/LockScreenLyrics/LockScreenLyrics.h"
#import "Shared/LyricsSources/LyricsSources.h"

SGModSection *SGLyricsSourcesSection(BOOL namingSource) {
    SGModRow *sources = SGPageRow(@"Sources", ^UIViewController *{ return SGLyricsSourcesPage(); });
    sources.value = ^NSString *{
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        for (NSString *key in SGLyricsOrder()) [names addObject:SGLyricsProviderFor(key).name];
        return names.count ? [names componentsJoinedByString:@", "] : @"Off";
    };
    SGModRow *imported = SGPageRow(@"Imported LRC files", ^UIViewController *{ return SGImportedLRCPage(); });
    imported.value = ^NSString *{
        NSUInteger count = SGImportedLRCFiles().count;
        return count ? @(count).stringValue : @"None";
    };
    NSMutableArray<SGModRow *> *rows = [NSMutableArray arrayWithObjects:sources, imported,
        SGOptionRow(@"Lyrics for every track", @"Even where Spotify has none", SGKeyLyricsAllTracks), SGSpicyLyricsKeyRow(), nil];
    if (namingSource) [rows addObject:SGOptionRow(@"Show source", nil, SGKeyLyricsCredit)];
    if (SGEeveeLyricsOn()) {
        [rows addObject:SGOptionRow(@"Use these sources anyway", @"Only if EeveeSpotify's lyrics are really off", SGKeyLyricsBesideEevee)];
        return SGNotedSection(@"Sources", rows, @"EeveeSpotify's lyrics are on, so it answers Spotify's lyrics and these sources stay "
                                                @"off: both answering froze Spotify after launch. Turn its lyrics off in its own "
                                                @"settings to use these.");
    }
    return SGSection(@"Sources", rows);
}

SGModRow *SGLockScreenLyricsRow(void) {
    return SGOptionRow(@"Lock screen lyrics", @"Current line in place of the artist", SGKeyLockScreenLyrics);
}

SGModRow *SGLyricsTranslationLanguageRow(void) {
    SGModRow *row = SGChoiceRow(@"Translation language", nil, SGKeyLyricsTranslationLanguage, SGLyricsTranslationLanguageNames(), 0);
    row.choiceFooter = @"A language brings Musixmatch's community translations to lyrics that have none, "
                       @"which sends Musixmatch each song's ID. Any shows the first translation the lyrics come with.";
    return row;
}

// Only the redesign's lyrics view sweeps words.
SGModRow *SGLyricsWordTimingRow(void) {
    return SGOptionRow(@"Simulate word timing", nil, SGKeyLyricsSimulateWords);
}
