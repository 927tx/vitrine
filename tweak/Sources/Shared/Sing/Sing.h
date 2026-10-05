// Sing: a song's vocals turned down while it plays, from a mic button on the redesigned player's lyrics
// (Redesigned/Lyrics/SGRSingButton.m) and the Sing page (Sing on Mod Settings' main page, and Lyrics > Karaoke),
// under either look: the work is on Spotify's sound.
//
//     SGSingModel.m       the voice model: downloaded, each file checked against its size and SHA-256, loaded
//     SGSingLoader.m      the model in memory: a CPU copy, then a faster one beside it, each load with a deadline
//     SGSingSeparator.m   the STFT around the model: two seconds in, their vocals out, on the copy that fits
//     SGSingEngine.m      Spotify's mixer pulled ahead of what plays, the vocals separated in the lead, mixed down
//                         and put where spatial voice holds them
//     Sing.x              the engine put between Spotify's mixer and its output (through Shared/Player/SpeedPitch.x's
//                         chain), Spotify's clock and seeks kept true to what plays, the heat, what Sing is doing,
//                         and the head's turn for spatial voice (Shared/HeadGestures' motion)
//     SingSettings.m      the Sing page, and Spatial voice's under it
//     SGSingCard.m        the Sing page's card: the song, Sing's state, the vocals and the rest traced live, the level
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

@class SPTPlayerState;

// The mic: on and off at once, from the button or the Sing page; off until switched on.
#define SGKeySing @"spotifyglass.sing"
// The vocals' level, 0 (gone) through 1 (as the song has them) to 2 (the vocals alone) at the slider's top.
#define SGKeySingLevel @"spotifyglass.sing.level"
// Keeps the model running on a hot iPhone, which otherwise lets it go from the thermal state Serious up.
#define SGKeySingIgnoreHeat @"spotifyglass.sing.ignoreHeat"
// Where the model runs beside the CPU: an index into SGSingComputeUnitNames(), Automatic (0) unless chosen. The
// earlier key held the one place the model ran (GPU, GPU and Neural Engine, Neural Engine) and is carried over.
#define SGKeySingComputeUnits @"spotifyglass.sing.runsOn"
#define SGKeySingComputeUnitsBefore @"spotifyglass.sing.computeUnits"
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
    SGSingStatePreparing,     // the model loading (only while Spotify is active), which Core ML specialises the first time
    SGSingStateWaiting,       // on, the model ready, Spotify not playing through the chain yet; or resting at As sung
                              // (SGSingStatusText says which)
    SGSingStateBuffering,     // on, the lead filling: what plays is dry
    SGSingStateSinging,       // on, the vocals down
    SGSingStateBehind,        // on, the model slower than the song: what plays is dry until it catches up
    SGSingStateHot,           // on, held for the heat, the model let go
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
// The loudness (RMS) of the vocals and of the rest of the song as heard, per tenth of a second, for the `count`
// tenths up to what plays now, oldest first; NO, and nothing written, unless Sing is turning the vocals down now.
// Reading them says a page shows them: with the vocals as sung and Spatial voice off, Sing separates only while
// they are read (at least once a second), and otherwise rests and plays the song as it is.
BOOL SGSingReadLevels(float *vocals, float *rest, int count);
// A level as the slider reads it out: Gone, a percentage, As sung, Backing and a percentage, Vocals only.
NSString *SGSingLevelText(double level);
void SGSetSingIgnoresHeat(BOOL ignores);
// Seconds of Spotify's sound Sing holds ahead of what plays now, as the render thread left it; 0 when none.
double SGSingHeldLead(void);
// The seconds to take off `state`'s position for what is heard: the lead held when the clock's line `state` is on
// began (its first state seen), less what Sing dropped since (SGSingEngineLeadAt). Every correction for the lead reads
// this; 0 while Sing never ran.
double SGSingLeadOf(SPTPlayerState *state);
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
// Spatial voice's page, its preview and its switch: under Sing's page, and on Mod Settings' main page under Sing.
UIViewController *SGSpatialVoiceSettingsPage(void);
// Loads the faster copy again on the compute units now stored, the CPU's kept.
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
// Whether the download is held until the iPhone is online again, or on Wi-Fi unless cellular is allowed.
BOOL SGSingModelWaitingForNetwork(void);
// The download over cellular and Low Data Mode networks too, which it otherwise waits out; for this launch.
void SGSingDownloadModelOverCellular(void);
BOOL SGSingModelOverCellular(void);
// The weights' checksum being read, the download's last step.
BOOL SGSingModelChecking(void);
// Bytes a stopped download kept for the next one to carry on from; 0 when there are none.
long long SGSingModelPausedBytes(void);
// The last download's failure, nil when there was none (too little free space among them: the download does not
// start then).
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
