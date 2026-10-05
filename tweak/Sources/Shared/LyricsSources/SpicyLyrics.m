// Spicy Lyrics, through its Developer Platform (developers.spicylyrics.org) on the user's own key.
// One request by Spotify's track id answers with the best sync there is: a community one made by
// hand, else Apple Music's or Spotify's. Syllable syncs time every syllable and carry duets and
// backing vocals. The key lives in the Keychain, not in the settings, so a settings export never
// carries it; without one the source answers nothing.
//
// The API's terms ask for the provider to be named wherever its lyrics show, and for a community
// sync's maker and uploader to be credited with it; the credit says so, and reads where every
// source's does, under Show source.
#import <Security/Security.h>
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "LyricsSources.h"

static NSString *const kAPI = @"https://api.spicylyrics.org/v1/lyrics/";
static NSString *const kService = @"Vitrine.SpicyLyrics", *const kAccount = @"api-key";
NSString *const SGSpicyLyricsKey = @"spicylyrics";

#pragma mark - the key

static NSDictionary *keyQuery(void) {
    return @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
             (__bridge id)kSecAttrService: kService, (__bridge id)kSecAttrAccount: kAccount};
}

static NSString *storedKey(void) {
    NSMutableDictionary *query = [keyQuery() mutableCopy];
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef data = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &data) != errSecSuccess || !data) return nil;
    NSString *key = [[NSString alloc] initWithData:(__bridge_transfer NSData *)data encoding:NSUTF8StringEncoding];
    return key.length ? key : nil;
}

static void storeKey(NSString *key) {
    SecItemDelete((__bridge CFDictionaryRef)keyQuery());
    if (!key.length) return;
    NSMutableDictionary *item = [keyQuery() mutableCopy];
    item[(__bridge id)kSecValueData] = [key dataUsingEncoding:NSUTF8StringEncoding];
    item[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    OSStatus status = SecItemAdd((__bridge CFDictionaryRef)item, NULL);
    if (status != errSecSuccess) SGLog(@"spicy lyrics: the key could not be kept (%d)", (int)status);
}

BOOL SGSpicyLyricsKeySet(void) {
    return storedKey() != nil;
}

#pragma mark - the response

static NSInteger ms(id seconds) {
    return [seconds respondsToSelector:@selector(doubleValue)] ? (NSInteger)llround([seconds doubleValue] * 1000) : 0;
}

static NSString *stringIn(NSDictionary *object, NSString *name) {
    id value = [object isKindOfClass:NSDictionary.class] ? object[name] : nil;
    return [value isKindOfClass:NSString.class] && [value length] ? value : nil;
}

// The API does not say what language a TranslatedText is in, so it is taken only while the Lyrics page
// asks for any. With a language chosen, the line is left without one for Musixmatch or Gemini to fill
// in that language, as an Apple Music translation in another language is left out (SGTTML.m).
static NSString *translationIn(NSDictionary *object) {
    return SGLyricsTranslationLanguage() ? nil : stringIn(object, @"TranslatedText");
}

static NSArray *arrayIn(NSDictionary *object, NSString *name) {
    id value = [object isKindOfClass:NSDictionary.class] ? object[name] : nil;
    return [value isKindOfClass:NSArray.class] ? value : @[];
}

// A Lead or Background: its syllables as words. IsPartOfWord says a syllable runs on into the next
// one, so the next is laid flush against it.
static SGKaraokeLine *syllableLine(NSDictionary *part) {
    NSMutableArray<SGKaraokeWord *> *words = [NSMutableArray array];
    BOOL runsOn = NO;
    for (NSDictionary *syllable in arrayIn(part, @"Syllables")) {
        NSString *text = [stringIn(syllable, @"Text") stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!text.length) continue;
        SGKaraokeWord *word = [SGKaraokeWord new];
        word.text = text;
        word.start = ms(syllable[@"StartTime"]);
        word.end = MAX(ms(syllable[@"EndTime"]), word.start);
        word.joined = words.count && runsOn;
        [words addObject:word];
        runsOn = [syllable[@"IsPartOfWord"] boolValue];
    }
    if (!words.count) return nil;
    SGKaraokeLine *line = [SGKaraokeLine new];
    line.words = words;
    line.start = words.firstObject.start;
    line.end = MAX(words.lastObject.end, line.start);
    line.translation = translationIn(part);
    return line;
}

static NSArray<SGKaraokeLine *> *syllableLines(NSArray *content) {
    NSMutableArray<SGKaraokeLine *> *lines = [NSMutableArray array];
    for (NSDictionary *item in content) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        SGKaraokeLine *line = syllableLine(item[@"Lead"]);
        if (!line) continue;
        line.align = [item[@"OppositeAligned"] boolValue] ? SGKaraokeAlignTrailing : SGKaraokeAlignLeading;
        // A line can have several background phrases; the view has one backing line, so they share it.
        NSMutableArray *backing = [NSMutableArray array];
        for (NSDictionary *group in arrayIn(item, @"Background")) [backing addObjectsFromArray:arrayIn(group, @"Syllables")];
        line.backing = syllableLine(@{@"Syllables": backing});
        [lines addObject:line];
    }
    return lines.count ? lines : nil;
}

static BOOL isBreak(NSString *text) {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return !trimmed.length || [trimmed isEqualToString:@"♪"];
}

// Starts only; the words inside are estimated. A line that ends well before the next begins gets an
// empty line at its end, so the estimate does not stretch it over the pause.
static NSArray<SGKaraokeLine *> *lineLines(NSArray *content) {
    NSMutableArray<NSDictionary *> *kept = [NSMutableArray array];
    for (NSDictionary *item in content) {
        if (!isBreak(stringIn(item, @"Text"))) [kept addObject:item];
    }
    NSMutableArray<NSNumber *> *starts = [NSMutableArray array];
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    for (NSUInteger i = 0; i < kept.count; i++) {
        [starts addObject:@(ms(kept[i][@"StartTime"]))];
        [texts addObject:kept[i][@"Text"]];
        NSInteger end = ms(kept[i][@"EndTime"]);
        if (end > 0 && i + 1 < kept.count && ms(kept[i + 1][@"StartTime"]) > end) {
            [starts addObject:@(end)];
            [texts addObject:@""];
        }
    }
    NSArray<SGKaraokeLine *> *lines = SGKaraokeEstimatedLines(starts, texts);
    // Breaks were left out of kept, so the lines and kept pair up one to one.
    for (NSUInteger i = 0; i < lines.count && i < kept.count; i++) {
        if ([kept[i][@"OppositeAligned"] boolValue]) lines[i].align = SGKaraokeAlignTrailing;
        lines[i].translation = translationIn(kept[i]);
    }
    return lines;
}

static NSArray<SGKaraokeLine *> *staticLines(NSArray *rows) {
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    for (NSDictionary *row in rows) {
        NSString *text = stringIn(row, @"Text");
        if (text) [texts addObject:text];
    }
    return SGKaraokeStaticLines(texts);
}

// What the credit reads. A community sync names the people who made it; a catalogue's is named as
// the provider it is, reached through Spicy Lyrics.
static NSString *creditFor(NSDictionary *body) {
    NSString *source = stringIn(body, @"source");
    if ([source isEqualToString:@"apple_music"]) return @"Apple Music via Spicy Lyrics";
    if ([source isEqualToString:@"spotify"]) return @"Spotify via Spicy Lyrics";
    NSDictionary *people = body[@"UploadAttribution"];
    NSString *maker = stringIn([people isKindOfClass:NSDictionary.class] ? people[@"Maker"] : nil, @"username");
    NSString *uploader = stringIn([people isKindOfClass:NSDictionary.class] ? people[@"Uploader"] : nil, @"username");
    if (maker && uploader && ![maker isEqualToString:uploader]) {
        return [NSString stringWithFormat:@"Spicy Lyrics, synced by %@, uploaded by %@", maker, uploader];
    }
    if (maker ?: uploader) return [NSString stringWithFormat:@"Spicy Lyrics, synced by %@", maker ?: uploader];
    return @"Spicy Lyrics";
}

SGLyricsResult *SGSpicyLyricsResult(id root) {
    NSDictionary *body = [root isKindOfClass:NSDictionary.class] ? root[@"Body"] : nil;
    if (![body isKindOfClass:NSDictionary.class]) return nil;
    NSString *type = stringIn(body, @"Type");
    NSArray<SGKaraokeLine *> *lines = [type isEqualToString:@"Syllable"] ? syllableLines(arrayIn(body, @"Content"))
        : [type isEqualToString:@"Line"] ? lineLines(arrayIn(body, @"Content"))
        : [type isEqualToString:@"Static"] ? staticLines(arrayIn(body, @"Lines"))
        : nil;
    if (!lines) return nil;
    SGLyricsResult *result = [SGLyricsResult new];
    result.provider = creditFor(body);
    result.karaokeLines = lines;
    result.wordTimed = SGKaraokeLinesTiming(lines) == SGKaraokeTimingWords;
    result.synced = SGKaraokeLinesTiming(lines) != SGKaraokeTimingNone;
    NSArray<NSNumber *> *starts;
    NSArray<NSString *> *texts;
    if (result.synced) {
        SGLyricsPageLines(lines, &starts, &texts);
    } else {
        NSMutableArray<NSNumber *> *zeros = [NSMutableArray array];
        NSMutableArray<NSString *> *plain = [NSMutableArray array];
        for (SGKaraokeLine *line in lines) {
            [zeros addObject:@0];
            [plain addObject:SGKaraokeLineText(line)];
        }
        starts = zeros;
        texts = plain;
    }
    result.starts = starts;
    result.texts = texts;
    return result;
}

#pragma mark - asking

SGLyricsAsk SGSpicyLyricsAsk = ^(SGLyricsQuery *query, void (^done)(SGLyricsResult *result)) {
    NSString *key = storedKey();
    // The API takes Spotify's 22 character base62 id and nothing else.
    if (!key || query.trackID.length != 22) {
        done(nil);
        return;
    }
    NSURL *url = [NSURL URLWithString:[kAPI stringByAppendingString:query.trackID]];
    SGLyricsGetJSON(url, @{@"Authorization": [@"Bearer " stringByAppendingString:key]}, ^(id root) {
        SGLyricsResult *result = SGSpicyLyricsResult(root);
        SGLog(@"spicy lyrics: %@ %@", query.trackID, result
              ? [NSString stringWithFormat:@"has %lu %@ lines, credited to %@", (unsigned long)result.karaokeLines.count,
                 result.wordTimed ? @"word timed" : result.synced ? @"line timed" : @"untimed", result.provider]
              : @"has nothing");
        done(result);
    });
};

#pragma mark - the row

// A key saved puts the source at the top of the order, since it was set to be used; a key removed
// takes it out, as it can answer nothing without one.
static void setKey(NSString *key) {
    storeKey(key);
    NSMutableArray<NSString *> *order = [SGLyricsOrder() mutableCopy];
    [order removeObject:SGSpicyLyricsKey];
    if (key.length) [order insertObject:SGSpicyLyricsKey atIndex:0];
    SGLyricsSetOrder(order);
}

static void askForKey(void) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Spicy Lyrics key"
        message:@"Create an application at developers.spicylyrics.org and paste its secret key (sl_sk_). A publishable key does not work from an app. The key stays on this iPhone."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"sl_sk_...";
        field.secureTextEntry = YES;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *key = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (key.length) setKey(key);
    }]];
    if (SGSpicyLyricsKeySet()) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Remove" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            setKey(nil);
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

SGModRow *SGSpicyLyricsKeyRow(void) {
    return SGStatActionRow(@"Spicy Lyrics key", @"Community word syncs, with your own key",
                           ^NSString *{ return SGSpicyLyricsKeySet() ? @"Set" : @"Off"; }, ^{ askForKey(); });
}
