#import <Security/Security.h>
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/LyricsSources/LyricsSources.h"
#import "LyricsTranslation.h"

// gemini-flash-latest follows each Flash release; Google gives two weeks' notice of a breaking change.
static NSString *const kEndpoint = @"https://generativelanguage.googleapis.com/v1beta/models/gemini-flash-latest:generateContent";
static NSString *const kService = @"Vitrine.Gemini", *const kAccount = @"api-key";

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
    if (status != errSecSuccess) SGLog(@"gemini: the key could not be kept (%d)", (int)status);
}

BOOL SGGeminiKeySet(void) {
    return storedKey() != nil;
}

#pragma mark - asking

NSString *SGLyricsGeminiLanguage(void) {
    return SGLyricsTranslationLanguage() ?: [NSLocale.preferredLanguages.firstObject componentsSeparatedByString:@"-"].firstObject ?: @"en";
}

static NSMutableDictionary<NSString *, NSArray<NSString *> *> *sg_done;   // per launch, by track and language

void SGLyricsTranslateWithGemini(NSString *trackID, NSArray<SGKaraokeLine *> *lines, NSString *languageTag,
                                 void (^done)(NSArray<NSString *> *translations, NSString *error)) {
    NSString *key = storedKey();
    if (!key) {
        done(nil, @"Add a Gemini API key on the Lyrics page first.");
        return;
    }
    if (!sg_done) sg_done = [NSMutableDictionary dictionary];
    NSString *memo = [NSString stringWithFormat:@"%@|%@", trackID, languageTag];
    if (trackID && sg_done[memo].count == lines.count) {
        done(sg_done[memo], nil);
        return;
    }
    NSMutableArray<NSString *> *texts = [NSMutableArray arrayWithCapacity:lines.count];
    for (SGKaraokeLine *line in lines) [texts addObject:SGKaraokeLineText(line) ?: @""];
    NSString *language = [[NSLocale localeWithLocaleIdentifier:@"en"] localizedStringForLanguageCode:languageTag] ?: languageTag;
    NSData *input = [NSJSONSerialization dataWithJSONObject:texts options:0 error:nil];
    NSString *prompt = [NSString stringWithFormat:
        @"Translate the lines of this song into %@. Answer with a JSON array of exactly %lu strings, one "
        @"per input line and in the same order. Translate the meaning naturally, keep each line short like a "
        @"lyric, and keep an empty line empty. A line already in %@ stays as it is.\n\n%@",
        language, (unsigned long)texts.count, language, [[NSString alloc] initWithData:input encoding:NSUTF8StringEncoding]];
    NSDictionary *body = @{
        @"contents": @[@{@"parts": @[@{@"text": prompt}]}],
        @"generationConfig": @{
            @"responseMimeType": @"application/json",
            @"responseSchema": @{@"type": @"ARRAY", @"items": @{@"type": @"STRING"}},
        },
    };
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kEndpoint]];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 60;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:key forHTTPHeaderField:@"x-goog-api-key"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        id root = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSArray *translations = nil;
        NSString *problem = nil;
        id candidates = [root isKindOfClass:NSDictionary.class] ? root[@"candidates"] : nil;
        id first = [candidates isKindOfClass:NSArray.class] ? [candidates firstObject] : nil;
        id parts = [first isKindOfClass:NSDictionary.class] && [first[@"content"] isKindOfClass:NSDictionary.class] ? first[@"content"][@"parts"] : nil;
        id text = [parts isKindOfClass:NSArray.class] && [[parts firstObject] isKindOfClass:NSDictionary.class] ? [parts firstObject][@"text"] : nil;
        id parsed = [text isKindOfClass:NSString.class] ? [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
        if ([parsed isKindOfClass:NSArray.class] && [parsed count] == texts.count) {
            NSMutableArray<NSString *> *clean = [NSMutableArray arrayWithCapacity:texts.count];
            for (id line in parsed) [clean addObject:[line isKindOfClass:NSString.class] ? line : @""];
            translations = clean;
        } else if (error) {
            problem = @"Gemini could not be reached.";
        } else if (status == 400 || status == 403) {
            problem = @"Gemini turned the key down. Check it on the Lyrics page.";
        } else if (status == 429) {
            problem = @"Gemini's limit for this key is reached for now.";
        } else {
            problem = [NSString stringWithFormat:@"Gemini did not translate the song (%ld).", (long)status];
        }
        SGLog(@"gemini: %@ lines into %@: %@", @(texts.count), languageTag, translations ? @"translated" : problem);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (translations && trackID) sg_done[memo] = translations;
            done(translations, problem);
        });
    }] resume];
}

#pragma mark - the row

static void askForKey(void) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Gemini API key"
        message:@"Lyrics translate into any language with your own key, from Google AI Studio. It stays on this iPhone."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"API key";
        field.secureTextEntry = YES;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *key = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        storeKey(key);
    }]];
    if (SGGeminiKeySet()) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Remove" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            storeKey(nil);
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

SGModRow *SGGeminiKeyRow(void) {
    return SGStatActionRow(@"Gemini API key", @"Translate any song from the lyrics' corner menu",
                           ^NSString *{ return SGGeminiKeySet() ? @"Set" : @"Off"; }, ^{ askForKey(); });
}
