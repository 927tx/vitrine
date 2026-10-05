// Sing on Spotify's sound (Sing.h): the engine put between Spotify's mixer and its output, the voice model
// loaded while the mic is on, Spotify's clock and seeks kept true to what plays, the heat, and what Sing is
// doing for the button and the page.
//
// The engine sits in the chain Speed and pitch takes over (Shared/Player/SpeedPitch.x): its stage is handed
// the mixer's pull, so the engine can pull the mixer ahead of what plays. It takes Spotify's sound as Spotify
// hands it to the RemoteIO unit, which this file reads when Spotify starts the unit (Spotify's import of
// AudioOutputUnitStart rebound, as Music Haptics and the audio effects do): Sing needs it at the model's
// 44.1 kHz, float, a buffer per channel, two channels, and otherwise passes it as it is.
//
// The lead is sound Spotify's decoder has handed over and the speaker has not played yet, and Spotify's clock
// counts what the decoder handed over. -[SPTPlayerState position] is [self positionAsOfTimestamp] run on by
// the time since (disassembly at 0x1057735ec, its -1 kept for no position), so positionAsOfTimestamp is
// hooked to take the lead off: the scrubber, the lyrics and the lock screen follow what is heard. A seek, a
// skip or a stop drops the lead (-[SPTEsperantoPlayer seekTo:...] and skipTo...TrackWithOptions:track:loggingParams:
// in the binary's method list, each returning Spotify's own result for the command; the shorter skips are
// trampolines into those two through objc_msgSend, 0x1096da9e4-0x1096daa08), and so does a track changing well
// before the last one ended: something new was played.
//
// The model is held only while the mic is on, and loaded on a queue of its own. From the thermal state
// Serious on, the engine is held and plays dry, unless Ignore heat warnings is on.
//
// Threading: the stage on the render thread; Spotify starts its output on a thread of its own; the rest main.
#import <AudioToolbox/AudioToolbox.h>
#import <CoreML/CoreML.h>
#import <pthread.h>
#import <stdatomic.h>
#import "Core/SGCore.h"
#import "Core/SGRebind.h"
#import "Shared/Player/PlayerState.h"
#import "Shared/Player/SpeedPitch.h"
#import "Sing.h"
#import "SGSingEngine.h"
#import "SGSingSeparator.h"

// The vocals' level until one is chosen: down to a guide.
static const float kDefaultLevel = 0.15f;
// How often what Sing is doing is read while the mic is on.
static const NSTimeInterval kWatchEvery = 0.5;
// A track changing more than this before the last one's end is something new played, not the next track.
static const double kEndSlack = 2;

static _Atomic(SGSingEngine *) sg_engine;   // made the first time the mic is on, never freed
static atomic_bool sg_formatTaken;          // Spotify's output is in a format Sing takes
static atomic_bool sg_staged;               // the stage has run: Spotify's sound comes through the chain
static atomic_bool sg_formatRefused;        // the stage was handed buffers it does not take
static atomic_bool sg_outputStarted;        // Spotify has started its RemoteIO unit

#pragma mark - the render thread

typedef struct {
    SGPlayerPull pull;
    void *context;
} ChainPull;

static OSStatus pullChain(void *context, UInt32 frames, float *left, float *right) {
    ChainPull *chain = context;
    struct { AudioBufferList list; AudioBuffer second; } buffers = {{2, {{1, frames * 4, left}}}, {1, frames * 4, right}};
    return chain->pull(chain->context, frames, &buffers.list);
}

static OSStatus stage(UInt32 frames, AudioBufferList *data, SGPlayerPull pull, void *context) {
    SGSingEngine *engine = atomic_load_explicit(&sg_engine, memory_order_acquire);
    if (!engine) return pull(context, frames, data);
    atomic_store_explicit(&sg_staged, true, memory_order_relaxed);
    BOOL takes = atomic_load_explicit(&sg_formatTaken, memory_order_relaxed) && data->mNumberBuffers == 2;
    for (UInt32 b = 0; takes && b < 2; b++) {
        takes = data->mBuffers[b].mData && data->mBuffers[b].mNumberChannels == 1 && data->mBuffers[b].mDataByteSize == frames * sizeof(float);
    }
    if (!takes) {
        atomic_store_explicit(&sg_formatRefused, true, memory_order_relaxed);
        return pull(context, frames, data);
    }
    ChainPull chain = {pull, context};
    return SGSingEngineRender(engine, frames, data->mBuffers[0].mData, data->mBuffers[1].mData, pullChain, &chain);
}

#pragma mark - Spotify's audio thread

static OSStatus (*sg_startOutput)(AudioUnit unit);

static OSStatus startOutput(AudioUnit unit) {
    AudioComponentDescription description = {0};
    if (unit && AudioComponentGetDescription(AudioComponentInstanceGetComponent(unit), &description) == noErr
        && description.componentType == kAudioUnitType_Output && description.componentSubType == kAudioUnitSubType_RemoteIO) {
        atomic_store_explicit(&sg_outputStarted, true, memory_order_relaxed);
        AudioStreamBasicDescription format = {0};
        UInt32 size = sizeof format;
        OSStatus status = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, &size);
        BOOL takes = status == noErr && format.mFormatID == kAudioFormatLinearPCM && format.mSampleRate == kSGSingRate
                     && format.mChannelsPerFrame == 2 && format.mBitsPerChannel == 32 && (format.mFormatFlags & kAudioFormatFlagIsFloat)
                     && (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved);
        if (takes != atomic_exchange(&sg_formatTaken, takes) || !takes) {
            SGLog(@"sing: Spotify hands its output %.0f Hz, %u channels, %u bits, flags 0x%x: %@", format.mSampleRate,
                  (unsigned)format.mChannelsPerFrame, (unsigned)format.mBitsPerChannel, (unsigned)format.mFormatFlags,
                  takes ? @"Sing takes it" : @"not a format Sing takes, its sound passes as it is");
        }
    }
    return sg_startOutput(unit);
}

#pragma mark - the model

static SGSingSeparator *sg_separator;
static BOOL sg_loading;
static NSString *sg_loadError;
static NSUInteger sg_loadGeneration;   // counts the mic's switches, so a load finished after it went off is dropped
static BOOL sg_hot;

static void announce(void) {
    [NSNotificationCenter.defaultCenter postNotificationName:SGSingChangedNotification object:nil];
}

static dispatch_queue_t loadQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("spotifyglass.sing.load", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
    });
    return queue;
}

static MLComputeUnits computeUnits(void) {
    switch (SGInt(SGKeySingComputeUnits, 0)) {
        case 1: return MLComputeUnitsAll;
        case 2: return MLComputeUnitsCPUAndNeuralEngine;
        default: return MLComputeUnitsCPUAndGPU;
    }
}

static void loadModel(void) {
    NSURL *url = SGSingModelURL();
    if (sg_separator || sg_loading || !url || SGSingMissing()) return;
    sg_loading = YES;
    sg_loadError = nil;
    NSUInteger generation = sg_loadGeneration;
    MLComputeUnits units = computeUnits();
    SGLog(@"sing: loading the voice model");
    dispatch_async(loadQueue(), ^{
        CFAbsoluteTime began = CFAbsoluteTimeGetCurrent();
        MLModelConfiguration *configuration = [MLModelConfiguration new];
        configuration.computeUnits = units;
        NSError *error;
        MLModel *model = [MLModel modelWithContentsOfURL:url configuration:configuration error:&error];
        SGSingSeparator *separator = model ? [[SGSingSeparator alloc] initWithModel:model] : nil;
        double took = CFAbsoluteTimeGetCurrent() - began;
        dispatch_async(dispatch_get_main_queue(), ^{
            sg_loading = NO;
            if (!separator) {
                sg_loadError = error.localizedDescription ?: @"The voice model could not be loaded";
                SGLog(@"sing: the voice model did not load: %@", sg_loadError);
            } else if (generation == sg_loadGeneration) {
                sg_separator = separator;
                SGSingEngineSetSeparator(atomic_load(&sg_engine), separator);
                SGLog(@"sing: the voice model is loaded in %.1f s", took);
            }
            announce();
        });
    });
}

static void unloadModel(void) {
    sg_loadGeneration++;
    sg_separator = nil;
    SGSingEngine *engine = atomic_load(&sg_engine);
    if (engine) SGSingEngineSetSeparator(engine, nil);
}

#pragma mark - the state

static void watch(void);

static void apply(void) {
    BOOL on = SGSingOn() && !SGSingMissing();
    SGSingEngine *engine = atomic_load(&sg_engine);
    if (on && !engine) {
        engine = SGSingEngineCreate();
        if (!engine) {
            sg_loadError = @"Sing could not set aside memory for the song";
            return;
        }
        SGSingEngineSetLevel(engine, SGSingLevel());
        atomic_store_explicit(&sg_engine, engine, memory_order_release);
    }
    if (!engine) return;
    SGSingEngineSetPaused(engine, sg_hot && !SGHidden(SGKeySingIgnoreHeat));
    SGSingEngineSetOn(engine, on);
    if (on) loadModel();
    else unloadModel();
    watch();
}

BOOL SGSingOn(void) {
    return SGHidden(SGKeySing);
}

void SGSetSingOn(BOOL on) {
    SGSetEnabled(SGKeySing, on);
    sg_loadError = nil;   // switched on again, a failed load is tried again
    SGLog(@"sing: the mic is %@", on ? @"on" : @"off");
    apply();
    announce();
}

float SGSingLevel(void) {
    NSNumber *stored = [NSUserDefaults.standardUserDefaults objectForKey:SGKeySingLevel];
    return stored ? fmaxf(0, fminf(stored.floatValue, 2)) : kDefaultLevel;
}

void SGSetSingLevel(float level) {
    level = fmaxf(0, fminf(level, 2));
    [NSUserDefaults.standardUserDefaults setFloat:level forKey:SGKeySingLevel];
    SGSingEngine *engine = atomic_load(&sg_engine);
    if (engine) SGSingEngineSetLevel(engine, level);
}

void SGSingComputeUnitsChanged(void) {
    unloadModel();
    apply();
    announce();
}

void SGSetSingIgnoresHeat(BOOL ignores) {
    SGSetEnabled(SGKeySingIgnoreHeat, ignores);
    apply();
    announce();
}

NSString *SGSingMissing(void) {
    if (!SGSingOSSupported()) return [NSString stringWithFormat:@"Sing needs iOS 18, the first its voice model runs on. This iPhone has iOS %@.", UIDevice.currentDevice.systemVersion];
    if (!SGSingDeviceSupported()) return @"Sing needs an iPhone with 6 GB of memory or more, which the voice model was built for. This one has less.";
    if (SGSingModelCurrentState() != SGSingModelReady) return [NSString stringWithFormat:@"Sing needs its voice model, which is downloaded from Mod Settings > Sing (%@).", SGSingModelSizeText()];
    return nil;
}

SGSingState SGSingCurrentState(void) {
    if (!SGSingOSSupported() || !SGSingDeviceSupported()) return SGSingStateUnavailable;
    SGSingModelState model = SGSingModelCurrentState();
    if (model == SGSingModelDownloading) return SGSingStateDownloading;
    if (model != SGSingModelReady) return SGSingStateNoModel;
    if (!SGSingOn()) return SGSingStateOff;
    SGSingEngine *engine = atomic_load(&sg_engine);
    if (sg_loadError || !engine || (engine && SGSingEngineError(engine))) return SGSingStateFailed;
    if (sg_loading || !sg_separator) return SGSingStatePreparing;
    if (sg_hot && !SGHidden(SGKeySingIgnoreHeat)) return SGSingStateHot;
    // Spotify plays and Speed and pitch never took its output over: the stage, and so Sing, never runs.
    if (!atomic_load(&sg_staged) && atomic_load(&sg_outputStarted) && !SGPlayerSpeedAllowed()) return SGSingStateFailed;
    if (!sg_startOutput || (atomic_load(&sg_staged) && atomic_load(&sg_formatRefused) && !atomic_load(&sg_formatTaken))) return SGSingStateFailed;
    SGSingEngineStats stats = SGSingEngineReadStats(engine);
    if (!atomic_load(&sg_staged) || stats.lead < 0.05) return SGSingStateWaiting;
    if (stats.ready > 0) return SGSingStateSinging;
    // The lead is full and the vocals are still not in: the model is slower than the song.
    if (stats.windows && (stats.averageMS > kSGSingEngineHop * 1000.0 / kSGSingRate || stats.lead >= stats.targetLead - 0.25)) return SGSingStateBehind;
    return SGSingStateBuffering;
}

NSString *SGSingStatusText(void) {
    switch (SGSingCurrentState()) {
        case SGSingStateUnavailable: return @"Unavailable";
        case SGSingStateNoModel: return @"Needs its voice model";
        case SGSingStateDownloading:
            if (SGSingModelWaitingForNetwork()) return @"Waiting for the network";
            return [NSString stringWithFormat:@"Downloading %.0f%%", SGSingModelProgress() * 100];
        case SGSingStateOff: return @"Off";
        case SGSingStatePreparing: return @"Preparing";
        case SGSingStateWaiting: return @"Waiting for Spotify";
        case SGSingStateBuffering: return @"Listening ahead";
        case SGSingStateSinging: return @"On";
        case SGSingStateBehind: return @"Too slow";
        case SGSingStateHot: return @"Held, too hot";
        case SGSingStateFailed: return @"Failed";
    }
    return @"";
}

NSString *SGSingStatusDetail(void) {
    switch (SGSingCurrentState()) {
        case SGSingStateUnavailable:
        case SGSingStateNoModel:
            return SGSingMissing();
        case SGSingStateDownloading:
            if (SGSingModelWaitingForNetwork()) {
                return [NSString stringWithFormat:@"The iPhone is offline. The voice model's download carries on from %.0f%% of %@ once it is online again.",
                        SGSingModelProgress() * 100, SGSingModelSizeText()];
            }
            return [NSString stringWithFormat:@"The voice model is coming in, %.0f%% of %@. Sing starts once it is checked.", SGSingModelProgress() * 100, SGSingModelSizeText()];
        case SGSingStateWaiting:
            return @"Sing starts once Spotify plays a song.";
        case SGSingStatePreparing:
            return @"Core ML prepares the voice model for this iPhone. The first time, that can take a minute.";
        case SGSingStateBuffering:
            return @"Sing listens a few seconds ahead of what plays, so the vocals are separated before you hear them. Until then the song plays as it is.";
        case SGSingStateBehind: {
            SGSingEngine *engine = atomic_load(&sg_engine);
            double ms = engine ? SGSingEngineReadStats(engine).averageMS : 0;
            return [NSString stringWithFormat:@"The voice model takes %.1f s for every 1.5 s of song on this iPhone, so the vocals stay in until it catches up. Another choice under Runs on may be faster.", ms / 1000];
        }
        case SGSingStateHot:
            return @"The iPhone is hot, so Sing is held and the song plays as it is until it cools down. Ignore heat warnings keeps Sing going.";
        case SGSingStateFailed: {
            SGSingEngine *engine = atomic_load(&sg_engine);
            NSString *error = sg_loadError ?: (engine ? SGSingEngineError(engine) : nil);
            if (error) return error;
            if (!sg_startOutput) return @"Spotify's output could not be reached.";
            if (!atomic_load(&sg_staged) && !SGPlayerSpeedAllowed()) return @"Spotify's output could not be taken over, so Sing cannot reach its sound.";
            return @"Spotify's output is not 44.1 kHz stereo, which the voice model needs, so the song plays as it is.";
        }
        default:
            return nil;
    }
}

NSString *SGSingSummary(void) {
    switch (SGSingCurrentState()) {
        case SGSingStateUnavailable: return @"Unavailable";
        case SGSingStateNoModel: return @"Off";
        case SGSingStateDownloading: return [NSString stringWithFormat:@"%.0f%%", SGSingModelProgress() * 100];
        case SGSingStateOff: return @"Off";
        default: return @"On";
    }
}

#pragma mark - watching while the mic is on

static NSTimer *sg_watch;
static SGSingState sg_shown = -1;
static NSString *sg_shownText;
static NSString *sg_lastTrack;
static double sg_lastRaw = -1, sg_lastDuration;
static CFAbsoluteTime sg_lastFlush;
static __thread BOOL sg_rawPosition;   // the hook below hands Spotify's own value back

static double rawPosition(SPTPlayerState *state) {
    sg_rawPosition = YES;
    double position = state.position;
    sg_rawPosition = NO;
    return position;
}

static void flush(NSString *why) {
    SGSingEngine *engine = atomic_load(&sg_engine);
    if (!engine || SGSingEngineLead(engine) <= 0) return;
    sg_lastFlush = CFAbsoluteTimeGetCurrent();
    SGSingEngineFlush(engine);
    SGLog(@"sing: %@, the %.1f s held ahead are dropped", why, SGSingEngineLead(engine));
}

static void tick(void) {
    SGSingState state = SGSingCurrentState();
    NSString *text = SGSingStatusText();
    if (state != sg_shown || ![text isEqualToString:sg_shownText]) {
        sg_shown = state;
        sg_shownText = text;
        announce();
    }
    SPTPlayerState *player = SGPlayerState();
    if (player) {
        sg_lastRaw = rawPosition(player);
        sg_lastDuration = player.duration;
    }
    SGSingEngine *engine = atomic_load(&sg_engine);
    // Now and then while on, what the model costs on this iPhone.
    static CFAbsoluteTime summarized;
    if (engine && SGSingOn() && CFAbsoluteTimeGetCurrent() - summarized >= 30) {
        summarized = CFAbsoluteTimeGetCurrent();
        SGSingEngineStats stats = SGSingEngineReadStats(engine);
        SGLog(@"sing: %@, %llu windows at %.0f ms each (1500 ms keeps up), lead %.2f s of %.2f s, %.2f s separated ahead, %llu frames dry, %llu failures",
              SGSingStatusText(), stats.windows, stats.averageMS, stats.lead, stats.targetLead, stats.ready, stats.dryFrames, stats.failures);
    }
    // Off, with the lead given back: nothing left to watch.
    if (!SGSingOn() && (!engine || SGSingEngineLead(engine) <= 0)) {
        [sg_watch invalidate];
        sg_watch = nil;
    }
}

static void watch(void) {
    if (sg_watch) return;
    sg_watch = [NSTimer scheduledTimerWithTimeInterval:kWatchEvery repeats:YES block:^(NSTimer *timer) { tick(); }];
    tick();
}

@interface SGSingTrackWatcher : NSObject <SGPlayerStateObserver>
@end

@implementation SGSingTrackWatcher
// A new track well before the last one's end was played, not reached: the lead is the old track's.
- (void)playerStateDidChange:(SPTPlayerState *)state {
    NSString *track = SGURIString(state.track.URI);
    if (track && sg_lastTrack && ![track isEqualToString:sg_lastTrack] && sg_lastRaw >= 0 && sg_lastDuration > 0
        && sg_lastDuration - sg_lastRaw > kEndSlack + kWatchEvery && CFAbsoluteTimeGetCurrent() - sg_lastFlush > 1) {
        flush(@"another track was played");
    }
    if (track) sg_lastTrack = track;
}
@end

#pragma mark - the heat

static void readHeat(void) {
    BOOL hot = NSProcessInfo.processInfo.thermalState >= NSProcessInfoThermalStateSerious;
    if (hot == sg_hot) return;
    sg_hot = hot;
    SGLog(@"sing: the iPhone is %@%@", hot ? @"hot" : @"cool again", hot && SGHidden(SGKeySingIgnoreHeat) ? @", and heat warnings are ignored" : @"");
    apply();
    announce();
}

#pragma mark - Spotify's clock and commands

%hook SPTPlayerState
- (double)positionAsOfTimestamp {
    double position = %orig;
    if (sg_rawPosition || position < 0) return position;
    SGSingEngine *engine = atomic_load_explicit(&sg_engine, memory_order_acquire);
    double lead = engine ? SGSingEngineLead(engine) : 0;
    return lead > 0 ? MAX(0, position - lead) : position;
}
%end

%hook SPTEsperantoPlayer
- (id)seekTo:(double)position {
    flush(@"Spotify seeks");
    return %orig;
}
- (id)seekTo:(double)position relative:(long long)relative {
    flush(@"Spotify seeks");
    return %orig;
}
- (id)seekTo:(double)position options:(id)options {
    flush(@"Spotify seeks");
    return %orig;
}
- (id)seekTo:(double)position relative:(long long)relative options:(id)options {
    flush(@"Spotify seeks");
    return %orig;
}
- (id)seekTo:(double)position relative:(long long)relative options:(id)options creatorTimestampPositionMs:(double)creator {
    flush(@"Spotify seeks");
    return %orig;
}
// Every skip of Spotify's ends up in one of these two.
- (id)skipToNextTrackWithOptions:(id)options track:(id)track loggingParams:(id)params {
    flush(@"Spotify skips");
    return %orig;
}
- (id)skipToPreviousTrackWithOptions:(id)options track:(id)track loggingParams:(id)params {
    flush(@"Spotify skips back");
    return %orig;
}
- (id)stop {
    flush(@"Spotify stops");
    return %orig;
}
%end

%ctor {
    if (!SGRebindImport("AudioOutputUnitStart", startOutput, (void **)&sg_startOutput) || !sg_startOutput) {
        sg_startOutput = NULL;
        SGLog(@"sing: Spotify does not import AudioOutputUnitStart, Sing cannot read its output");
    }
    SGPlayerSetStage(stage);
    %init;
    SGRequireClasses(@[@"SPTPlayerState", @"SPTEsperantoPlayer"]);
    dispatch_async(dispatch_get_main_queue(), ^{
        static SGSingTrackWatcher *watcher;
        watcher = [SGSingTrackWatcher new];
        SGAddPlayerStateObserver(watcher);
        [NSNotificationCenter.defaultCenter addObserverForName:NSProcessInfoThermalStateDidChangeNotification object:nil queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *note) { readHeat(); }];
        [NSNotificationCenter.defaultCenter addObserverForName:SGSingChangedNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
            // A download finishing with the mic already on loads the model.
            if (SGSingOn() && !sg_separator && !sg_loading && !sg_loadError) apply();
        }];
        readHeat();
        if (SGSingOn()) apply();
    });
}
