// Sing: a song's vocals turned down while it plays, from a mic button on the redesigned player's lyrics
// (Redesigned/Lyrics/SGRSingButton.m) and the Sing page (Sing on Mod Settings' main page, and Lyrics > Karaoke),
// under either look: the work is on Spotify's sound.
//
//     SGSingModel.m       the voice model: downloaded, each file checked against its size and SHA-256, loaded
//     SGSingSeparator.m   the STFT around the model: two seconds in, their vocals out
//     SGSingEngine.m      Spotify's mixer pulled ahead of what plays, the vocals separated in the lead, mixed down
//                         and put where spatial voice holds them
//     Sing.x              the engine put between Spotify's mixer and its output (through Shared/Player/SpeedPitch.x's
//                         chain), Spotify's clock and seeks kept true to what plays, the heat, what Sing is doing,
//                         and the head's turn for spatial voice (Shared/HeadGestures' motion)
//     SingSettings.m      the Sing page, and Spatial voice's under it
//     SGSpatialPreview.m  the Spatial voice page's preview: the voice in front of the listener on a field of dots,
//                         turned by the head the way the audio is
//
// The voice model is public and MIT licensed: Mel-Band RoFormer (Ju-Chiang Wang, Wei-Tsung Lu, Minz Won) with
// KimberleyJensen's vocal checkpoint, its spectral core exported for Core ML with two-second windows, from
// https://huggingface.co/My-Name-Is-Jeff/vitrine-sing, a mirror of Darkkos/spoti-sing (App/About/Licenses.m carries
// its notice). Its floor is iOS 18, the Core ML it was built with. No audio leaves the phone.
//
// Threading: main thread, but for what Sing.x's render side and the engine say.
#import <UIKit/UIKit.h>

// The mic: on and off at once, from the button or the Sing page; off until switched on.
#define SGKeySing @"spotifyglass.sing"
// The vocals' level, 0 (gone) through 1 (as the song has them) to 2 (the vocals alone) at the slider's top.
#define SGKeySingLevel @"spotifyglass.sing.level"
// Keeps the model running on a hot iPhone, which otherwise holds it from Serious on.
#define SGKeySingIgnoreHeat @"spotifyglass.sing.ignoreHeat"
// Where the model runs: an index into SGSingComputeUnitNames(), read as it loads.
#define SGKeySingComputeUnits @"spotifyglass.sing.computeUnits"
// Spatial voice: through headphones that track the head, the vocals stay in front as it turns; off until
// switched on, and at once.
#define SGKeySingSpatial @"spotifyglass.sing.spatial"

// Posted on the main thread whenever what Sing is doing, or its model's download, changes.
extern NSString *const SGSingChangedNotification;

typedef NS_ENUM(NSInteger, SGSingState) {
    SGSingStateUnavailable,   // the OS or the iPhone cannot run it (SGSingMissing says which)
    SGSingStateNoModel,       // the model is not downloaded
    SGSingStateDownloading,
    SGSingStateOff,
    SGSingStatePreparing,     // the model loading, which Core ML specialises for the phone the first time
    SGSingStateWaiting,       // on, Spotify not playing through the chain yet
    SGSingStateBuffering,     // on, the lead filling: what plays is dry
    SGSingStateSinging,       // on, the vocals down
    SGSingStateBehind,        // on, the model slower than the song: what plays is dry until it catches up
    SGSingStateHot,           // on, held for the heat
    SGSingStateFailed,        // the model or Spotify's output failed (SGSingStatusDetail says how)
};
SGSingState SGSingCurrentState(void);
// What Sing is doing, a few words for the button's label and the page, and what it means where there is
// more to say (what is missing, why it failed), nil otherwise.
NSString *SGSingStatusText(void);
NSString *SGSingStatusDetail(void);
// Which of the OS, the voice model or the iPhone Sing was built for is missing; nil when none is.
NSString *SGSingMissing(void);

BOOL SGSingOn(void);
void SGSetSingOn(BOOL on);
float SGSingLevel(void);
void SGSetSingLevel(float level);
// A level as the slider reads it out: Gone, a percentage, As sung, Backing and a percentage, Vocals only.
NSString *SGSingLevelText(double level);
void SGSetSingIgnoresHeat(BOOL ignores);
// Whether this iPhone runs Sing and reads headphone motion, which spatial voice needs.
BOOL SGSingSpatialAvailable(void);
BOOL SGSingSpatial(void);
// Stored, the motion's permission asked for when it goes on, and applied at once.
void SGSetSingSpatial(BOOL on);

// The top of the Spatial voice page: listener and voice on a field of dots seen from behind the head, which
// follows the head through HeadGestures' motion while it is on screen and the motion is allowed, and idles
// otherwise, a line under it saying which.
@interface SGSpatialPreview : UIView
// Reads the switch and the motion's permission again.
- (void)refresh;
@end
// Loads the model again on the compute units now stored, if it is loaded.
void SGSingComputeUnitsChanged(void);
// What the main page's Sing row reads out: On, Off, or how far the model has come.
NSString *SGSingSummary(void);
UIViewController *SGSingSettingsPage(void);

#pragma mark - the model (SGSingModel.m)

typedef NS_ENUM(NSInteger, SGSingModelState) {
    SGSingModelMissing,
    SGSingModelDownloading,
    SGSingModelReady,         // on the phone, every file checked
};
SGSingModelState SGSingModelCurrentState(void);
// 0 to 1 while downloading.
double SGSingModelProgress(void);
// Whether the download is held until the iPhone is online again.
BOOL SGSingModelWaitingForNetwork(void);
// The last download's failure, nil when there was none.
NSString *SGSingModelError(void);
// The download's size, for the row that offers it.
NSString *SGSingModelSizeText(void);
void SGSingDownloadModel(void);
void SGSingCancelModelDownload(void);
void SGSingDeleteModel(void);
// The compiled model's folder, nil until it is ready.
NSURL *SGSingModelURL(void);
NSArray<NSString *> *SGSingComputeUnitNames(void);
// Whether this OS can load the model (iOS 18) and this iPhone was built to run it.
BOOL SGSingOSSupported(void);
BOOL SGSingDeviceSupported(void);
