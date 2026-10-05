// Sing's voice model in memory (Sing.h): loaded, warmed, kept a minute after the mic goes off, and dropped.
//
// A copy on the CPU alone comes first, since that is the one Core ML has always loaded: once one prediction of
// silence has warmed it, the separator is Ready and Sing works. Then, while Spotify is in the foreground, a faster
// copy on the units asked for (the GPU unless the Sing page's Runs on says otherwise) loads beside it, warms the
// same way and is handed to the separator, which uses it for the windows while Spotify is in the foreground. A
// second copy loads only when the process has comfortably more memory left than a copy takes.
//
// Core ML cannot cancel a load, and on an iPhone 15 Pro one has never come back. So each load runs on a queue of its
// own, has a deadline, and is abandoned when the deadline passes or the model is dropped: abandoned, it is left to
// finish or hang where it is, and whatever it brings back later is let go. A CPU copy past its deadline makes Sing
// Failed until the mic is switched off and on; a faster copy past its deadline leaves Sing on the CPU's.
//
// Threading: main thread, but for SGSingLoaderSeparator's separator, which the engine's worker runs.
#import <CoreML/CoreML.h>

@class SGSingSeparator;

typedef NS_ENUM(NSInteger, SGSingLoaderState) {
    SGSingLoaderIdle,      // nothing loaded or loading
    SGSingLoaderLoading,   // the CPU copy loading or warming
    SGSingLoaderReady,     // the CPU copy warm: SGSingLoaderSeparator separates
    SGSingLoaderFailed,    // the CPU copy did not load (SGSingLoaderError says why); stays so until a retry
};

// What became of the faster copy.
typedef NS_ENUM(NSInteger, SGSingFastState) {
    SGSingFastNone,        // none asked for, or not yet started
    SGSingFastLoading,
    SGSingFastReady,
    SGSingFastSkipped,     // too little memory for a second copy
    SGSingFastFailed,      // Core ML refused it, or its warm-up failed
    SGSingFastTimedOut,    // past its deadline; SGSingLoaderFastTimedOutActive says whether Spotify stayed active through it
};

// Run on the main thread whenever the state, the separator or the faster copy changes.
void SGSingLoaderSetChanged(void (^changed)(void));
// Loads the model at `url` or joins the load already running, with `fast` the units of the faster copy
// (MLComputeUnitsCPUOnly for none); a different `fast` than before drops the faster copy for the new one. Does
// nothing while Failed. Call it only while Spotify is in the foreground.
void SGSingLoaderWant(NSURL *url, MLComputeUnits fast);
// The mic is off: the copies are kept for SGSingLoaderKeepSeconds, then dropped unless wanted again by then.
// Failed is cleared, so the next want is a fresh load whatever an abandoned one is still doing.
void SGSingLoaderRelease(void);
// Both copies dropped at once and any load abandoned, `why` logged when there was something to drop.
void SGSingLoaderPurge(NSString *why);
// The faster copy alone dropped (a memory warning), the CPU's kept.
void SGSingLoaderDropFast(NSString *why);
// Spotify became active or stopped being active: the faster copy is used only while it is, and starts loading
// when it becomes so.
void SGSingLoaderSetForeground(BOOL foreground);

SGSingLoaderState SGSingLoaderCurrentState(void);
// Whether the process has the memory left for a copy (always, where the OS does not say).
BOOL SGSingLoaderHasRoom(void);
// Nil until Ready.
SGSingSeparator *SGSingLoaderSeparator(void);
NSString *SGSingLoaderError(void);
// Seconds since the CPU copy began loading, while Loading.
NSTimeInterval SGSingLoaderSeconds(void);
SGSingFastState SGSingLoaderFastState(void);
BOOL SGSingLoaderFastTimedOutActive(void);
MLComputeUnits SGSingLoaderFastUnits(void);
// "GPU", "Neural Engine", "GPU and Neural Engine", "CPU".
NSString *SGSingUnitsName(MLComputeUnits units);
// Loads started since launch, and loads not come back yet (abandoned ones with them), for the harness.
unsigned SGSingLoaderAttempts(void);
unsigned SGSingLoaderOutstanding(void);

// The deadlines and the minute kept, in seconds; changed only by the harness.
extern double SGSingLoaderCPUDeadline, SGSingLoaderFastDeadline, SGSingLoaderKeepSeconds;
