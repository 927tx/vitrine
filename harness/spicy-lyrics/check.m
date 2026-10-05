// Reads made-up Spicy Lyrics API responses through the real SGSpicyLyricsResult and checks the lines
// and the credit. The responses follow the shapes in developers.spicylyrics.org's Get Lyrics reference;
// the words are filler. Exits non-zero on the first wrong answer.
#import <UIKit/UIKit.h>
#import "Shared/LyricsSources/LyricsSources.h"

// What SpicyLyrics.m reaches outside the parser for; none of it but the result class is used here.
@implementation SGLyricsResult
@end
void SGLyricsPageLines(NSArray<SGKaraokeLine *> *lines, NSArray<NSNumber *> **starts, NSArray<NSString *> **texts) {
    *starts = [lines valueForKey:@"start"];
    *texts = @[];
}
void SGLyricsGetJSON(NSURL *url, NSDictionary *headers, void (^done)(id root)) { done(nil); }
NSArray<NSString *> *SGLyricsOrder(void) { return @[]; }
void SGLyricsSetOrder(NSArray<NSString *> *keys) {}
SGModRow *SGStatActionRow(NSString *t, NSString *s, NSString *(^v)(void), void (^a)(void)) { return nil; }
UIViewController *SGTopController(void) { return nil; }
static NSString *sg_language;   // the Lyrics page's translation language, nil for Any
NSString *SGLyricsTranslationLanguage(void) { return sg_language; }

#define CHECK(cond) do { if (!(cond)) { fprintf(stderr, "FAILED line %d: %s\n", __LINE__, #cond); exit(1); } } while (0)

static SGLyricsResult *parse(NSString *json) {
    return SGSpicyLyricsResult([NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil]);
}

int main(void) {
    @autoreleasepool {
        SGLyricsResult *syllable = parse(@"{\"Body\":{\"Type\":\"Syllable\",\"source\":\"spicy_lyrics\",\"StartTime\":1.5,\"EndTime\":9,"
            "\"UploadAttribution\":{\"Uploader\":{\"username\":\"up\"},\"Maker\":{\"username\":\"mk\"}},"
            "\"Content\":["
            "{\"Type\":\"Vocal\",\"OppositeAligned\":false,\"Lead\":{\"StartTime\":1.5,\"EndTime\":3,\"TranslatedText\":\"tr\",\"Syllables\":["
            "{\"Text\":\"Ev\",\"StartTime\":1.5,\"EndTime\":1.8,\"IsPartOfWord\":true},"
            "{\"Text\":\"ery\",\"StartTime\":1.8,\"EndTime\":2.2,\"IsPartOfWord\":false},"
            "{\"Text\":\"day\",\"StartTime\":2.2,\"EndTime\":3,\"IsPartOfWord\":false}]},"
            "\"Background\":[{\"StartTime\":2.5,\"EndTime\":3.5,\"Syllables\":[{\"Text\":\"(oh)\",\"StartTime\":2.5,\"EndTime\":3.5}]},"
            "{\"StartTime\":3.6,\"EndTime\":3.9,\"Syllables\":[{\"Text\":\"(yeah)\",\"StartTime\":3.6,\"EndTime\":3.9}]}]},"
            "{\"Type\":\"Vocal\",\"OppositeAligned\":true,\"Lead\":{\"StartTime\":4,\"EndTime\":9,\"Syllables\":["
            "{\"Text\":\"two\",\"StartTime\":4,\"EndTime\":9}]}}]},\"Status\":200,\"Type\":\"object\"}");
        CHECK(syllable.karaokeLines.count == 2);
        CHECK(syllable.wordTimed && syllable.synced);
        SGKaraokeLine *first = syllable.karaokeLines[0];
        CHECK([SGKaraokeLineText(first) isEqualToString:@"Every day"]);
        CHECK(first.words[0].start == 1500 && first.words[1].end == 2200);
        CHECK(first.words[1].joined && !first.words[2].joined);
        CHECK(first.start == 1500 && first.end == 3000);
        CHECK([first.translation isEqualToString:@"tr"]);
        CHECK([SGKaraokeLineText(first.backing) isEqualToString:@"(oh) (yeah)"] && first.backing.start == 2500 && first.backing.end == 3900);
        CHECK(first.align == SGKaraokeAlignLeading && syllable.karaokeLines[1].align == SGKaraokeAlignTrailing);
        CHECK([syllable.provider isEqualToString:@"Spicy Lyrics, synced by mk, uploaded by up"]);

        SGLyricsResult *line = parse(@"{\"Body\":{\"Type\":\"Line\",\"source\":\"spotify\",\"Content\":["
            "{\"Type\":\"Vocal\",\"Text\":\"one line\",\"StartTime\":10.81,\"EndTime\":12,\"OppositeAligned\":false},"
            "{\"Type\":\"Vocal\",\"Text\":\"\",\"StartTime\":12,\"EndTime\":20},"
            "{\"Type\":\"Vocal\",\"Text\":\"two line\",\"StartTime\":20,\"EndTime\":23,\"OppositeAligned\":true,\"TranslatedText\":\"zwei\"}]}}");
        CHECK(line.karaokeLines.count == 2);
        CHECK(line.synced && !line.wordTimed);
        CHECK(line.karaokeLines[0].start == 10810 && line.karaokeLines[0].end <= 12000);
        CHECK(line.karaokeLines[1].align == SGKaraokeAlignTrailing);
        CHECK(!line.karaokeLines[0].translation && [line.karaokeLines[1].translation isEqualToString:@"zwei"]);
        CHECK([line.provider isEqualToString:@"Spotify via Spicy Lyrics"]);

        // With a language chosen, a translation the API names no language for is left out of both syncs.
        sg_language = @"es";
        CHECK(!parse(@"{\"Body\":{\"Type\":\"Line\",\"Content\":[{\"Text\":\"two line\",\"StartTime\":20,\"EndTime\":23,"
            "\"TranslatedText\":\"zwei\"}]}}").karaokeLines[0].translation);
        CHECK(!parse(@"{\"Body\":{\"Type\":\"Syllable\",\"Content\":[{\"Lead\":{\"TranslatedText\":\"tr\",\"Syllables\":["
            "{\"Text\":\"day\",\"StartTime\":2.2,\"EndTime\":3}]}}]}}").karaokeLines[0].translation);
        sg_language = nil;

        SGLyricsResult *plain = parse(@"{\"Body\":{\"Type\":\"Static\",\"source\":\"apple_music\",\"Lines\":[{\"Text\":\"a b\"},{\"Text\":\"\"},{\"Text\":\"c\"}]}}");
        CHECK(plain.karaokeLines.count == 2 && !plain.synced);
        CHECK([plain.texts isEqualToArray:(@[@"a b", @"c"])] && [plain.starts isEqualToArray:(@[@0, @0])]);
        CHECK([plain.provider isEqualToString:@"Apple Music via Spicy Lyrics"]);

        CHECK(!parse(@"{\"Body\":{\"Type\":\"Syllable\",\"Content\":[]}}"));
        CHECK(!parse(@"{\"error\":\"not found\"}"));
        puts("spicy lyrics: all checks passed");
    }
    return 0;
}
