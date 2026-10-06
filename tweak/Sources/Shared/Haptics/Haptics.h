// Vibrations (Mod Settings > Player > Vibrations), under either look: the Taptic Engine answering
// what a finger does to playback (Controls), and playing along with the music (Music Haptics).
//
//     SGFeedback.m         which tap each kind of control gets, played while Controls is on
//     ControlHaptics.x     the player's and the now playing bar's controls, the scrubber, the cover swipes, the gestures
//     MusicHaptics.x       Spotify's audio output listened to, and Core Haptics played along with it
//     SGMusicAnalyzer.m    the listening: taps and a rumble out of the samples
//     SystemMusicHaptics.x iOS's own Music Haptics given the song's Apple Music id or ISRC (Native iOS)
//     SGHapticTrack.m      the pure steps behind it: Spotify's extended metadata asked and read, Apple's songs matched
//     HapticsSettings.m    the Vibrations page: its cards, with each one's strength, what Music Haptics plays and follows
//     SGVibrationsPreview.m the rings at the top of the page, which ripple and play the first feature on when tapped
//
// Everything on them applies at once, without a restart. Everything hooked is Spotify's own (its controls
// by accessibility identifier, its scrubber, its cover and title lists, its audio unit), so all of it works
// on Spotify's own screens and on the redesign's alike. The redesigned lyrics page's tap to seek plays its
// feedback from Redesigned/Lyrics/SGRKaraokeView.m.
// Threading: main thread only.
#import <UIKit/UIKit.h>

#define SGKeyControlHaptics @"spotifyglass.haptics.controls"
// The Music Haptics switch of before the choice below; read once to pick the choice for someone who had it.
#define SGKeyMusicHaptics @"spotifyglass.haptics.music"
// Which Music Haptics plays, an SGMusicHapticsMode.
#define SGKeyMusicHapticsMode @"spotifyglass.haptics.music.mode"
// How hard the taps are, a percentage within the range below; 100 is the feel each shipped with.
#define SGKeyControlStrength @"spotifyglass.haptics.controls.strength"
#define SGKeyMusicStrength @"spotifyglass.haptics.music.strength"
// What Music Haptics plays along with, an SGMusicFollows.
#define SGKeyMusicFollows @"spotifyglass.haptics.music.follows"
// What the keys were called while this was the redesign's alone; the %ctors move them over.
#define SGKeyControlHapticsWas @"spotifyglass.redesign.haptics.controls"
#define SGKeyMusicHapticsWas @"spotifyglass.redesign.haptics.music"
#define SGKeyControlStrengthWas @"spotifyglass.redesign.haptics.controls.strength"
#define SGKeyMusicStrengthWas @"spotifyglass.redesign.haptics.music.strength"
#define SGKeyMusicFollowsWas @"spotifyglass.redesign.haptics.music.follows"

// Controls go softer only: most of their taps are UIKit's at full intensity already. Music Haptics goes
// either way: at 200% the rumble reaches 0.7 of the Taptic Engine's most, and most taps their most.
enum {
    SGControlStrengthMin = 10, SGControlStrengthMax = 100,
    SGMusicStrengthMin = 20, SGMusicStrengthMax = 200,
    SGStrengthStep = 10,
};

typedef NS_ENUM(NSInteger, SGMusicFollows) {
    SGMusicFollowsEverything,   // a tap on each kick and snare, and the rumble under the bass
    SGMusicFollowsBeat,         // a tap on each kick and snare, no rumble
    SGMusicFollowsBass,         // a tap on each kick, and the rumble
};

// Stored as the index into the settings' list, which leaves the last one out below iOS 18.
typedef NS_ENUM(NSInteger, SGMusicHapticsMode) {
    SGMusicHapticsOff,
    SGMusicHapticsGenerated,   // the mod's, worked out from the sound (MusicHaptics.x)
    SGMusicHapticsNative,      // iOS's own, iOS 18 and later (SystemMusicHaptics.x)
};

typedef NS_ENUM(NSInteger, SGFeedback) {
    SGFeedbackPlay,      // playback starts
    SGFeedbackPause,     // playback stops
    SGFeedbackSkip,      // previous, next, a jump in the song (a double tap, a lyric line)
    SGFeedbackToggle,    // shuffle, repeat
    SGFeedbackAdd,       // the add button: liked songs, a playlist
    SGFeedbackGrab,      // a finger takes the scrubber
    SGFeedbackDetent,    // the scrubber passing a tenth of the song, a cover swipe passing halfway
    SGFeedbackEdge,      // the scrubber reaching the start or the end
    SGFeedbackRelease,   // the scrubber let go
};

// Plays `feedback` while Controls is on.
void SGPlayFeedback(SGFeedback feedback);
// Wakes the Taptic Engine for feedback about to follow quickly (a finger on the scrubber).
void SGPrepareFeedback(SGFeedback feedback);

// Which Music Haptics plays. Native reads Off below iOS 18; nothing stored yet reads the old switch, on as
// Generated. Main thread.
SGMusicHapticsMode SGMusicHapticsModeNow(void);
// Posted on the main thread when the choice changes; both engines take it up at once.
extern NSNotificationName const SGMusicHapticsModeChangedNotification;
// From its strength and its choice of what to follow: reads them again, for the next tap.
void SGMusicHapticsSettingsChanged(void);
// One kick of Generated's at its strength, with the rumble under it unless it follows the beat alone, played
// at once: the Vibrations preview's tap. Nothing while Generated is not listening.
void SGMusicHapticsPreview(void);
// Each tap Generated plays from now on is handed to `watcher` on the main thread as it is felt, with its
// intensity before the strength, 0 to 1; nil stops it. Main thread.
void SGMusicHapticsWatchTaps(void (^watcher)(float intensity));
// What iOS's own Music Haptics is doing, for the settings to read out: SystemMusicHaptics.x sets it. Main thread.
NSString *SGMusicHapticsStatus(void);
void SGSetMusicHapticsStatus(NSString *status);

// A strength key's percentage as a factor, 1 for 100%, kept within its range.
double SGHapticsStrength(NSString *key);
SGMusicFollows SGMusicHapticsFollows(void);

// The Vibrations page, linked from Mod Settings' main page: the preview, then a card for Controls and one for Music
// Haptics, each opening out into its settings while it is on.
UIViewController *SGVibrationsSettingsPage(void);
// What the main page's Vibrations row reads out: which of the two are on.
NSString *SGVibrationsSummary(void);
