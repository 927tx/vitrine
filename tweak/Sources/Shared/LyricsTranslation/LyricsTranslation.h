// A song's lines translated into any language by Gemini, on the user's own API key, at a tap in the
// lyrics' corner menu. The key lives in the Keychain, not in the settings, so a settings export never
// carries it. Only the lyrics' text and the language go out, to Google's Gemini API.
#import <UIKit/UIKit.h>

@class SGKaraokeLine, SGModRow;

BOOL SGGeminiKeySet(void);

// One translation per line, in order, or nil and a message to show. Main queue. The same song in the
// same language is asked once a launch.
void SGLyricsTranslateWithGemini(NSString *trackID, NSArray<SGKaraokeLine *> *lines, NSString *languageTag,
                                 void (^done)(NSArray<NSString *> *translations, NSString *error));

// The language a translation is asked in: the Lyrics page's, else the phone's own.
NSString *SGLyricsGeminiLanguage(void);

// Gemini's reply read: one translation per line when it has exactly `count`, else nil and in `problem`
// why not (the key, the limit, a filter, a recitation stop, a line count that does not match).
NSArray<NSString *> *SGGeminiTranslationsIn(id root, NSInteger status, NSError *error, NSUInteger count, NSString **problem);

// The Lyrics page's row: shows whether a key is set, and sets or removes it.
SGModRow *SGGeminiKeyRow(void);
