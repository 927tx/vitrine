// Sing on Spotify's sound (Sing.h): the engine put between Spotify's mixer and its output, the voice model
// loaded while the mic is on, Spotify's clock and seeks kept true to what plays, the heat, and what Sing is
// doing for the button and the page.
//
// The engine sits in the chain Speed and pitch takes over (Shared/Player/SpeedPitch.x): its stage is handed
// the mixer's pull, so the engine can pull the mixer ahead of what plays. It takes Spotify's sound as Spotify
// hands it to the music's output, whose format this file reads each time Shared/Player says that output changed,
// started again or changed format (SGPlayerWatchMusicOutput; voice search's unit or a second chain's is not the
// music's): Sing needs it at the model's 44.1 kHz, float, a buffer per channel, two channels, and otherwise passes
// it as it is. A new output or a new format drops the sound held ahead, which was in the old one.
//
// The lead is sound Spotify's decoder has handed over and the speaker has not played yet, and Spotify's clock
// counts what the decoder handed over when the player reports. -[SPTPlayerState position] is [self
// positionAsOfTimestamp] run on by the time since [self timestamp] (disassembly at 0x1057735ec, its -1 kept for no
// position), and the player reports on a change (a seek, a pause, a track), not as it plays. So what is heard is the
// reported position less the lead held when that line of the clock began, less what was dropped since, and not
// less the lead now: a lead filling after a report does not move what is heard, and taking it off lagged the lyrics
// by it. A state stamped again on the same line (the same position run on at the same speed) is the same report, so
// the lead is looked up by the line, not by the state's stamp (SGSingLeadOf). positionAsOfTimestamp is hooked to take
// that off: the scrubber, the lyrics, the Live Activity and the lock screen follow what is heard. A seek, a
// skip or a stop drops the lead (-[SPTEsperantoPlayer seekTo:...] and skipTo...TrackWithOptions:track:loggingParams:
// in the binary's method list, each returning Spotify's own result for the command; the shorter skips are
// trampolines into those two through objc_msgSend, 0x1096da9e4-0x1096daa08), and so does a track changing well
// before the last one ended: something new was played.
//
// The model is loaded by SGSingLoader.m, only while Spotify is active and the mic is on, and kept a minute after the
// mic goes off. From the thermal state Serious up the engine is held, plays the song as it is and lets the model go,
// unless Ignore heat warnings is on; it loads again once the iPhone is back at Fair. The model is what heats it, so
// Sing does not keep a hot iPhone hot. A model that falls 8 s behind stops Sing for the rest of the song, which then
// plays as it is; Sing tries again with the next track, when the iPhone cools or when Runs on changes, and stays
// stopped after three in a row with no song kept up.
// With the vocals as sung, Spatial voice off and the Sing page's lines not on screen, what Sing plays is the song
// itself, so it rests: the engine is held as for the heat and the model kept a minute as for a mic switched off.
// Whenever Sing does not separate (stopped, held, resting, standing aside), the engine plays the sound it holds ahead
// on as it is, dry, and the clock stays corrected for it: letting it go mid-song would skip that much of the song.
// It goes where nothing heard is lost: a seek, a skip, Spotify's output stopping, or a pause, where Spotify is
// seeked back to what was heard (SGSingTrackWatcher).
//
// Spatial voice listens to Shared/HeadGestures' motion (the app's one CMHeadphoneMotionManager) while Sing is
// on and Spotify plays, and hands the engine the head's yaw off a front that follows where the head points over
// 20 s, so the voice drifts back ahead of a head that stays turned and the attitude's own drift never carries
// it off. With no motion (no such headphones, Motion & Fitness not allowed) the voice stays ahead. iOS's own
// spatial audio on the route already holds the whole song in place, so spatial voice stands down for it.
//
// Threading: the stage on the render thread; Spotify starts its output on a thread of its own; the head's
// motion on HeadGestures' queue; the rest main.
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreML/CoreML.h>
#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <pthread.h>
#import <stdatomic.h>
#import "Core/SGCore.h"
#import "Shared/HeadGestures/HeadGestures.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/Player/PlayerState.h"
#import "Shared/Player/SpeedPitch.h"
#import "Sing.h"
#import "SGSingEngine.h"
#import "SGSingLoader.h"
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
static atomic_bool sg_outputStarted;        // Spotify has started or connected the music's output
static BOOL sg_outputReachable;             // Shared/Player watches the music's output for Sing

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

// Under Shared/Player's lock, one call at a time: the last output and format seen are this function's own.
static void musicOutputChanged(AudioUnit output) {
    static AudioUnit last;
    static AudioStreamBasicDescription lastFormat;
    AudioStreamBasicDescription format = {0};
    BOOL known = output && SGPlayerMusicClientFormat(&format);
    atomic_store_explicit(&sg_outputStarted, output != NULL, memory_order_relaxed);
    BOOL takes = known && format.mFormatID == kAudioFormatLinearPCM && format.mSampleRate == kSGSingRate
                 && format.mChannelsPerFrame == 2 && format.mBitsPerChannel == 32 && (format.mFormatFlags & kAudioFormatFlagIsFloat)
                 && (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved);
    BOOL changed = output != last || memcmp(&format, &lastFormat, sizeof format) != 0;
    last = output;
    lastFormat = format;
    // The sound held ahead is the old output's or the old format's: dropped before the next render plays any of it.
    SGSingEngine *engine = atomic_load_explicit(&sg_engine, memory_order_acquire);
    if (changed && engine) SGSingEngineFlush(engine);
    if (takes != atomic_exchange(&sg_formatTaken, takes) || (changed && !takes)) {
        SGLog(@"sing: Spotify hands the music's output %.0f Hz, %u channels, %u bits, flags 0x%x: %@", format.mSampleRate,
              (unsigned)format.mChannelsPerFrame, (unsigned)format.mBitsPerChannel, (unsigned)format.mFormatFlags,
              takes ? @"Sing takes it" : output ? @"not a format Sing takes, its sound passes as it is" : @"no music output now");
    }
}

#pragma mark - the model

static NSString *sg_setupError;   // the engine could not be made
static NSString *sg_stopped;      // why Sing stopped by itself, with the switch still on
static NSString *sg_refused;      // why Sing stands aside for what plays now (AirPlay, not a song); clears by itself

// What stopped it. Falling behind tries again with the next track, when the iPhone cools or when Runs on changes;
// a memory warning with the next track once there is room for the model; this many falls behind in a row, with no
// song kept up between them, stay stopped until the switch goes off and on, so a phone that can never keep up does
// not start and give up all day.
typedef NS_ENUM(NSInteger, SGSingStop) { SGSingStopNone, SGSingStopBehind, SGSingStopMemory, SGSingStopForGood };
static SGSingStop sg_stopKind;
static const int kGiveUpsKept = 3;
static int sg_giveUps;            // falls behind since a song was last kept up
static BOOL sg_sangThisTrack;     // the vocals were down at some point of the track playing

// AirPlay's delay changes as it plays, and a podcast or an ad has no song to take the vocals from: Sing stands
// aside, the song plays as it is, and the model is kept for when it can run again. Whether that changed.
static BOOL readRefusal(void) {
    NSString *refused = nil;
    for (AVAudioSessionPortDescription *port in AVAudioSession.sharedInstance.currentRoute.outputs) {
        if ([port.portType isEqualToString:AVAudioSessionPortAirPlay]) refused = @"Karaoke does not run over AirPlay, whose delay changes as it plays, so the song plays as it is.";
    }
    NSString *uri = SGURIString(SGPlayerState().track.URI);
    if (!refused && uri && ![uri hasPrefix:@"spotify:track:"] && ![uri hasPrefix:@"spotify:local:"]) {
        refused = @"Karaoke turns down the vocals of songs, and what plays now is not one, so it plays as it is.";
    }
    if (refused == sg_refused || [refused isEqualToString:sg_refused]) return NO;
    sg_refused = refused;
    SGLog(@"sing: %@", refused ?: @"runs again: what plays is a song, not over AirPlay");
    return YES;
}
static BOOL sg_hot;
static BOOL sg_active;            // Spotify is the active app: the only time a load starts

static void announce(void) {
    [NSNotificationCenter.defaultCenter postNotificationName:SGSingChangedNotification object:nil];
}

// Runs on: Automatic, CPU only, GPU, Neural Engine, GPU and Neural Engine. Automatic is the GPU beside the CPU: on an
// M4 the GPU's copy runs a window in 405-525 ms against the CPU's 1.2 s, while the Neural Engine's copy, which
// leaves the model's float32 operations to the CPU, took 6.25 s. On an iPhone 15 Pro the GPU's load never came
// back from a background launch; it now loads only in the foreground, and a GPU load that runs past its deadline
// with Spotify active throughout keeps Automatic on the CPU alone for this iOS, until Runs on is changed.
static NSString *const kGPUStuckOn = @"spotifyglass.sing.gpuStuckOn";

static NSString *osBuild(void) {
    return NSProcessInfo.processInfo.operatingSystemVersionString;
}

static NSInteger runsOn(void) {
    return SGInt(SGKeySingComputeUnits, 0);
}

static BOOL gpuStuck(void) {
    return [[NSUserDefaults.standardUserDefaults stringForKey:kGPUStuckOn] isEqualToString:osBuild()];
}

static MLComputeUnits fastUnits(void) {
    switch (runsOn()) {
        case 1: return MLComputeUnitsCPUOnly;
        case 2: return MLComputeUnitsCPUAndGPU;
        case 3: return MLComputeUnitsCPUAndNeuralEngine;
        case 4: return MLComputeUnitsAll;
        default: return gpuStuck() ? MLComputeUnitsCPUOnly : MLComputeUnitsCPUAndGPU;
    }
}

// The loader's news: the separator into the engine, a GPU load stuck in the foreground remembered.
static void loaderChanged(void) {
    SGSingEngine *engine = atomic_load(&sg_engine);
    if (engine) SGSingEngineSetSeparator(engine, SGSingLoaderSeparator());
    if (SGSingLoaderFastState() == SGSingFastTimedOut && SGSingLoaderFastTimedOutActive() && runsOn() == 0
        && SGSingLoaderFastUnits() == MLComputeUnitsCPUAndGPU && !gpuStuck()
        && NSProcessInfo.processInfo.thermalState < NSProcessInfoThermalStateSerious) {
        [NSUserDefaults.standardUserDefaults setObject:osBuild() forKey:kGPUStuckOn];
        SGLog(@"sing: the GPU did not load on %@ with Spotify active, so Automatic stays on the CPU on this iOS", osBuild());
    }
    announce();
}

#pragma mark - spatial voice

static BOOL sg_spatialListening;
// On HeadGestures' motion queue only.
static SGSpatialFront sg_front;

static void headMoved(CMDeviceMotion *motion) {
    SGSingEngine *engine = atomic_load_explicit(&sg_engine, memory_order_acquire);
    if (!motion) {
        sg_front.hasFront = false;
        if (engine) SGSingEngineSetVoiceAngle(engine, 0);
        return;
    }
    double angle = SGSpatialVoiceAngle(&sg_front, motion.attitude.yaw, motion.timestamp);
    if (engine) SGSingEngineSetVoiceAngle(engine, (float)angle);
}

// iOS's own spatial audio (Spatialize Stereo, or a spatial headphone's own) on the route.
static BOOL systemSpatial(void) {
    for (AVAudioSessionPortDescription *port in AVAudioSession.sharedInstance.currentRoute.outputs) {
        if (port.spatialAudioEnabled) return YES;
    }
    return NO;
}

// Listens to the head while Sing is on, spatial voice is on and Spotify plays, and iOS does not hold the song in
// place itself; otherwise the voice goes back ahead (HeadGestures hands a listener taken out nil).
static void updateSpatial(void) {
    SPTPlayerState *player = SGPlayerState();
    BOOL wanted = SGSingOn() && !SGSingMissing() && SGSingSpatial() && player.isPlaying && !player.isPaused;
    BOOL listen = wanted && !systemSpatial();
    if (listen == sg_spatialListening) return;
    sg_spatialListening = listen;
    SGLog(@"sing: spatial voice %@", listen ? @"follows the head" : wanted ? @"stands down for iOS's own spatial audio" : @"is ahead");
    SGHeadMotionListen(@"sing", listen ? ^(CMDeviceMotion *motion) { headMoved(motion); } : nil);
}

BOOL SGSingSpatialAvailable(void) {
    return SGSingOSSupported() && SGSingDeviceSupported() && SGHeadGesturesAvailable();
}

BOOL SGSingSpatial(void) {
    return SGHidden(SGKeySingSpatial);
}

static void updateRest(void);

void SGSetSingSpatial(BOOL on) {
    SGSetEnabled(SGKeySingSpatial, on);
    // Asked while the Sing page is in front, rather than with the next song.
    if (on) SGHeadMotionAskPermission();
    updateSpatial();
    updateRest();
}

#pragma mark - the state

static void watch(void);

// Resting: nothing needs the model, so the engine is held as for the heat and the song plays straight. The vocals are
// as sung (which plays exactly the song), Spatial voice is off, and no page traces the lines: the Sing page's card
// reads them ten times a second while it shows (SGSingReadLevels), so a second without a read is the page gone.
static const CFTimeInterval kLinesGoneAfter = 1;
static CFAbsoluteTime sg_linesReadAt;
static BOOL sg_resting;

static BOOL restful(void) {
    BOOL held = sg_hot && !SGHidden(SGKeySingIgnoreHeat);
    return SGSingOn() && !SGSingMissing() && !held && !sg_stopped && !sg_refused && fabsf(SGSingLevel() - 1) <= 0.001f && !SGSingSpatial()
           && CFAbsoluteTimeGetCurrent() - sg_linesReadAt > kLinesGoneAfter;
}

static void apply(void) {
    BOOL on = SGSingOn() && !SGSingMissing();
    SGSingEngine *engine = atomic_load(&sg_engine);
    if (on && !engine) {
        engine = SGSingEngineCreate();
        if (!engine) {
            sg_setupError = @"Karaoke could not set aside memory for the song.";
            return;
        }
        SGSingEngineSetLevel(engine, SGSingLevel());
        atomic_store_explicit(&sg_engine, engine, memory_order_release);
    }
    BOOL held = sg_hot && !SGHidden(SGKeySingIgnoreHeat);
    // Off, the model is kept a minute for a quick off and on. Held for the heat, it is let go at once, which frees
    // its memory and stops its work; it loads again once the iPhone cools.
    // ponytail: a phone flickering about Serious loads and drops the model each time; add a cooling-off delay if logs show it.
    // Stopped by itself, the song plays as it is and the switch stays on to say why; the model is kept, but for a
    // memory warning's stop, which let it go. Resting, the model is kept as for a mic switched off.
    BOOL rest = restful(), toRest = rest && !sg_resting;
    if (rest != sg_resting) {
        sg_resting = rest;
        if (rest) SGLog(@"sing: rests, the vocals as sung, Spatial voice off and the lines not shown: the song plays as it is, the model kept %.0f s",
                        SGSingLoaderKeepSeconds);
        else if (on && !held && !sg_stopped && !sg_refused) SGLog(@"sing: separates again (the vocals at %.2f, Spatial voice %@, the lines %@)", SGSingLevel(),
                   SGSingSpatial() ? @"on" : @"off", CFAbsoluteTimeGetCurrent() - sg_linesReadAt > kLinesGoneAfter ? @"not shown" : @"shown");
    }
    if (sg_stopped || sg_refused) on = NO;
    else if (!on) SGSingLoaderRelease();
    else if (held) SGSingLoaderPurge(@"the iPhone is too hot (thermal state serious or above)");
    else if (rest) { if (toRest) SGSingLoaderRelease(); }
    else if (sg_active) SGSingLoaderWant(SGSingModelURL(), fastUnits());
    if (!engine) return;
    SGSingEngineSetSeparator(engine, SGSingLoaderSeparator());
    SGSingEngineSetPaused(engine, held || rest);
    SGSingEngineSetOn(engine, on);
    double lead = SGSingEngineLead(engine);
    if ((!on || held || rest) && lead > 0.05) SGLog(@"sing: keeps the %.2f s held ahead, played as it is, until Spotify pauses, seeks or skips", lead);
    updateSpatial();
    watch();
}

// Called as often as the slider moves: applies only when resting would change.
static void updateRest(void) {
    if (restful() != sg_resting) apply();
}

BOOL SGSingOn(void) {
    return SGHidden(SGKeySing);
}

void SGSetSingOn(BOOL on) {
    SGSetEnabled(SGKeySing, on);
    sg_stopped = nil;
    sg_stopKind = SGSingStopNone;
    sg_giveUps = 0;
    SGLog(@"sing: the mic is %@", on ? @"on" : @"off");
    apply();
    announce();
}

// A stop for falling behind is over (and one for memory too, with `memory` and room for the model): Sing tries again.
static void retry(NSString *why, BOOL memory) {
    BOOL behind = sg_stopKind == SGSingStopBehind, lowMemory = memory && sg_stopKind == SGSingStopMemory && SGSingLoaderHasRoom();
    if (!SGSingOn() || (!behind && !lowMemory)) return;
    sg_stopped = nil;
    sg_stopKind = SGSingStopNone;
    SGLog(@"sing: tries again, %@ (%d fell behind in a row)", why, sg_giveUps);
    apply();
    announce();
}

BOOL SGSingReadLevels(float *vocals, float *rest, int count) {
    // A page tracing the lines is on screen: Sing separates for it.
    sg_linesReadAt = CFAbsoluteTimeGetCurrent();
    if (sg_resting) updateRest();
    SGSingEngine *engine = atomic_load(&sg_engine);
    if (!engine || SGSingCurrentState() != SGSingStateSinging) return NO;
    SGSingEngineReadLevels(engine, vocals, rest, count);
    // As heard: the vocals' gain up to 1, then the rest's down to nothing at 2.
    float level = SGSingLevel(), vocalsGain = fminf(level, 1), restGain = level <= 1 ? 1 : 2 - level;
    for (int k = 0; k < count; k++) {
        vocals[k] *= vocalsGain;
        rest[k] *= restGain;
    }
    return YES;
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
    updateRest();
}

void SGSingComputeUnitsChanged(void) {
    // A choice made is a new try, the GPU's included.
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kGPUStuckOn];
    SGLog(@"sing: Runs on is now %@", SGSingComputeUnitNames()[(NSUInteger)MIN(MAX(runsOn(), 0), 4)]);
    // Somewhere else to run is a fresh try, however often it fell behind before.
    sg_giveUps = 0;
    if (sg_stopKind == SGSingStopForGood) sg_stopKind = SGSingStopBehind;
    retry(@"Runs on changed", NO);
    if (SGSingOn()) apply();
    announce();
}

void SGSetSingIgnoresHeat(BOOL ignores) {
    SGSetEnabled(SGKeySingIgnoreHeat, ignores);
    apply();
    announce();
}

NSString *SGSingMissing(void) {
    if (!SGSingOSSupported()) return [NSString stringWithFormat:@"Karaoke needs iOS 18, the first its voice model runs on. This iPhone has iOS %@.", UIDevice.currentDevice.systemVersion];
    if (!SGSingDeviceSupported()) return @"Karaoke needs an iPhone with 6 GB of memory or more, which the voice model was built for. This one has less.";
    if (SGSingModelCurrentState() != SGSingModelReady) return [NSString stringWithFormat:@"Karaoke needs its voice model, which is downloaded from Mod Settings > Karaoke (%@).", SGSingModelSizeText()];
    return nil;
}

SGSingState SGSingCurrentState(void) {
    if (!SGSingOSSupported() || !SGSingDeviceSupported()) return SGSingStateUnavailable;
    SGSingModelState model = SGSingModelCurrentState();
    if (model == SGSingModelDownloading) return SGSingStateDownloading;
    if (model != SGSingModelReady) return SGSingStateNoModel;
    if (!SGSingOn()) return SGSingStateOff;
    // Held for the heat, the model is let go: held, not loading.
    if (sg_hot && !SGHidden(SGKeySingIgnoreHeat)) return SGSingStateHot;
    SGSingEngine *engine = atomic_load(&sg_engine);
    if (sg_stopped || sg_refused || SGSingLoaderError() || !engine || SGSingEngineError(engine)) return SGSingStateFailed;
    // Resting, ready for the level to move, whether the model is still kept or not.
    if (sg_resting) return SGSingStateWaiting;
    if (!SGSingLoaderSeparator()) return SGSingStatePreparing;
    // Spotify plays and Speed and pitch never took its output over: the stage, and so Sing, never runs.
    if (!atomic_load(&sg_staged) && atomic_load(&sg_outputStarted) && !SGPlayerSpeedAllowed()) return SGSingStateFailed;
    if (!sg_outputReachable || (atomic_load(&sg_staged) && atomic_load(&sg_formatRefused) && !atomic_load(&sg_formatTaken))) return SGSingStateFailed;
    SGSingEngineStats stats = SGSingEngineReadStats(engine);
    if (!atomic_load(&sg_staged) || stats.lead < 0.05) return SGSingStateWaiting;
    if (stats.mixing) return SGSingStateSinging;
    // The lead is full and the vocals are still not in: the model is slower than the song.
    if (stats.windows && (stats.averageMS > kSGSingEngineHop * 1000.0 / kSGSingRate || stats.lead >= stats.targetLead - 0.25)) return SGSingStateBehind;
    return SGSingStateBuffering;
}

NSString *SGSingStatusText(void) {
    switch (SGSingCurrentState()) {
        case SGSingStateUnavailable: return @"Unavailable";
        case SGSingStateNoModel: return @"Needs its voice model";
        case SGSingStateDownloading:
            if (SGSingModelChecking()) return @"Checking the download";
            if (SGSingModelWaitingForNetwork()) return SGSingModelOverCellular() ? @"Waiting for the network" : @"Waiting for Wi-Fi";
            return [NSString stringWithFormat:@"Downloading %.0f%%", SGSingModelProgress() * 100];
        case SGSingStateOff: return @"Off";
        case SGSingStatePreparing: {
            NSTimeInterval seconds = SGSingLoaderSeconds();
            return seconds >= 1 ? [NSString stringWithFormat:@"Loading the voice model, %.0f s", seconds] : @"Loading the voice model";
        }
        case SGSingStateWaiting: return sg_resting ? @"As sung" : @"Ready";
        case SGSingStateBuffering: return @"Listening ahead";
        case SGSingStateSinging: return @"On";
        case SGSingStateBehind: return @"Too slow";
        case SGSingStateHot: return @"Held, too hot";
        case SGSingStateFailed:
            if (!sg_stopped && sg_refused) return [sg_refused containsString:@"AirPlay"] ? @"Off over AirPlay" : @"Songs only";
            return sg_stopped ? @"Stopped" : @"Failed";
    }
    return @"";
}

// Where the model runs now, for the details of a working Sing.
static NSString *runsOnNote(void) {
    MLComputeUnits units = SGSingLoaderFastUnits();
    NSString *name = SGSingUnitsName(units);
    if (units == MLComputeUnitsCPUOnly) {
        return runsOn() == 0 ? @"The GPU did not load on this iOS before, so Karaoke runs on the CPU alone. Choosing GPU under Runs on tries it again."
                             : @"Karaoke runs on the CPU alone, as Runs on says.";
    }
    switch (SGSingLoaderFastState()) {
        case SGSingFastNone: return [NSString stringWithFormat:@"Karaoke runs on the CPU; a copy for the %@ loads once Spotify is open.", name];
        case SGSingFastLoading: return [NSString stringWithFormat:@"Karaoke runs on the CPU while a copy for the %@ loads.", name];
        case SGSingFastReady: return [NSString stringWithFormat:@"Karaoke runs on the %@ while Spotify is open, and on the CPU in the background.", name];
        case SGSingFastSkipped: return [NSString stringWithFormat:@"Too little memory is left for a copy on the %@, so Karaoke runs on the CPU alone.", name];
        case SGSingFastFailed: return [NSString stringWithFormat:@"The %@ could not load the voice model, so Karaoke runs on the CPU alone.", name];
        case SGSingFastTimedOut: return [NSString stringWithFormat:@"The %@ did not load the voice model in %.0f minutes, so Karaoke runs on the CPU alone.", name, SGSingLoaderFastDeadline / 60];
    }
    return nil;
}

NSString *SGSingStatusDetail(void) {
    switch (SGSingCurrentState()) {
        case SGSingStateUnavailable:
        case SGSingStateNoModel:
            return SGSingMissing();
        case SGSingStateDownloading:
            if (SGSingModelWaitingForNetwork()) {
                if (!SGSingModelOverCellular()) {
                    return [NSString stringWithFormat:@"The voice model's download waits for Wi-Fi, as %@ is a lot of a cellular plan, and carries on from %.0f%% once "
                                                      @"the iPhone is on Wi-Fi. The Voice model row on the Karaoke page can let it use cellular.",
                            SGSingModelSizeText(), SGSingModelProgress() * 100];
                }
                return [NSString stringWithFormat:@"The iPhone is offline. The voice model's download carries on from %.0f%% of %@ once it is online again.",
                        SGSingModelProgress() * 100, SGSingModelSizeText()];
            }
            return [NSString stringWithFormat:@"The voice model is coming in, %.0f%% of %@. Karaoke starts once it is checked.", SGSingModelProgress() * 100, SGSingModelSizeText()];
        case SGSingStateWaiting:
            if (sg_resting) {
                return @"The vocals are as sung and Spatial voice is off, so the song plays as it is and the voice model rests. Karaoke starts again "
                       @"when the level moves, Spatial voice goes on, or the Karaoke page opens.";
            }
            return [NSString stringWithFormat:@"The voice model is ready, and Karaoke starts once Spotify plays a song. %@", runsOnNote()];
        case SGSingStatePreparing:
            if (SGSingLoaderCurrentState() == SGSingLoaderIdle) return @"The voice model loads once Spotify is open.";
            return [NSString stringWithFormat:@"Core ML prepares the voice model for this iPhone's CPU, %.0f s so far, then Karaoke starts. The first time, that can take a minute.",
                    SGSingLoaderSeconds()];
        case SGSingStateBuffering:
            return @"Karaoke listens a few seconds ahead of what plays, so the vocals are separated before you hear them. Until then the song plays as it is.";
        case SGSingStateSinging:
            return runsOnNote();
        case SGSingStateBehind: {
            SGSingEngine *engine = atomic_load(&sg_engine);
            double ms = engine ? SGSingEngineReadStats(engine).averageMS : 0;
            return [NSString stringWithFormat:@"The voice model takes %.1f s for every 1.5 s of song on this iPhone, so the vocals stay in until it catches up. %@",
                    ms / 1000, runsOnNote()];
        }
        case SGSingStateHot:
            return @"The iPhone is hot, so Karaoke has let go of the voice model and the song plays as it is. Karaoke loads it again once the iPhone cools. "
                   @"Ignore heat warnings keeps Karaoke going.";
        case SGSingStateFailed: {
            SGSingEngine *engine = atomic_load(&sg_engine);
            if (sg_stopped ?: sg_refused) return sg_stopped ?: sg_refused;
            NSString *error = SGSingLoaderError() ?: (engine ? SGSingEngineError(engine) : sg_setupError);
            if (SGSingLoaderError()) return [error stringByAppendingString:@" Switch Karaoke off and on again to try again."];
            if (error) return error;
            if (!sg_outputReachable) return @"Spotify's output could not be reached.";
            if (!atomic_load(&sg_staged) && !SGPlayerSpeedAllowed()) return @"Spotify's output could not be taken over, so Karaoke cannot reach its sound.";
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
static _Atomic CFAbsoluteTime sg_lastFlush;   // Sing.x's own flushes: each comes with a report of Spotify's
static __thread BOOL sg_rawPosition;   // the hook below hands Spotify's own value back

static double rawPosition(SPTPlayerState *state) {
    sg_rawPosition = YES;
    double position = state.position;
    sg_rawPosition = NO;
    return position;
}

double SGSingHeldLead(void) {
    return SGSingEngineLead(atomic_load_explicit(&sg_engine, memory_order_acquire));
}

// Spotify's clock runs on lines: a position at a moment, run on at the playback speed (paused, it holds). A seek, a
// track, a pause or a resume starts a new line; a state that is the same line stamped again later is not a new
// report of what the decoder handed over, so its lead is the one at the line's first state seen, not at its own
// timestamp. Two states are one line when they put the clock within kSameLine of each other at the same speed.
typedef struct {
    double origin;           // the position at the reference date, running; the held position, paused
    double speed;
    bool paused;
    CFAbsoluteTime firstAt;  // when the line began, by the first state of it seen
} ClockLine;
enum { kLines = 8 };
static const double kSameLine = 0.25;
static ClockLine sg_lines[kLines];
static unsigned sg_lineCount;
static os_unfair_lock sg_linesLock = OS_UNFAIR_LOCK_INIT;

static double rawAsOf(SPTPlayerState *state) {
    BOOL was = sg_rawPosition;
    sg_rawPosition = YES;
    double position = state.positionAsOfTimestamp;
    sg_rawPosition = was;
    return position;
}

// When the line `state` is on began, for the lead held then: the stamp of the first state of it seen. The stamp is this
// iPhone's clock, as -position runs on from it by timeIntervalSinceNow.
// ponytail: a line first seen through a state stamped after it began reads the lead of that later moment; Spotify's
// own UI, the lyrics and tick read the player at least twice a second, so that is a fill's half second at most.
static CFAbsoluteTime lineStart(SPTPlayerState *state, CFAbsoluteTime at, double asOf) {
    double speed = [state respondsToSelector:@selector(playbackSpeed)] ? state.playbackSpeed : 1;
    if (!(speed > 0)) speed = 1;
    bool paused = state.isPaused;
    double origin = paused ? asOf : asOf - at * speed;
    CFAbsoluteTime first = at;
    os_unfair_lock_lock(&sg_linesLock);
    bool found = false;
    for (unsigned k = 0; k < MIN(sg_lineCount, (unsigned)kLines) && !found; k++) {
        ClockLine *line = &sg_lines[(sg_lineCount - 1 - k) % kLines];
        // A state stamped after a seek, a skip or a pause's seek back is that report, a new line even where it runs on
        // from the last (a seek back to what was heard).
        CFAbsoluteTime flushed = atomic_load_explicit(&sg_lastFlush, memory_order_relaxed);
        bool reported = line->firstAt < flushed && flushed <= at;
        if (!reported && line->paused == paused && fabs(line->speed - speed) < 1e-3 && fabs(line->origin - origin) < kSameLine * (paused ? 1 : speed)) {
            first = line->firstAt;
            found = true;
        }
    }
    if (!found) sg_lines[sg_lineCount++ % kLines] = (ClockLine){origin, speed, paused, at};
    os_unfair_lock_unlock(&sg_linesLock);
    return first;
}

double SGSingLeadOf(SPTPlayerState *state) {
    SGSingEngine *engine = atomic_load_explicit(&sg_engine, memory_order_acquire);
    if (!engine || !state) return 0;
    NSDate *at = [state respondsToSelector:@selector(timestamp)] ? state.timestamp : nil;
    double asOf = rawAsOf(state);
    if (![at isKindOfClass:NSDate.class] || asOf < 0) return SGSingEngineLead(engine);
    return SGSingEngineLeadAt(engine, lineStart(state, at.timeIntervalSinceReferenceDate, asOf));
}

// The last absolute seek's target and the frames pulled when it was asked: from then to the next track, what is heard
// is the target run on by the frames played since, whatever Spotify's clock does. For the log only.
static double sg_seekTarget = -1;
static uint64_t sg_seekWritten;

static void seekAnchor(double target) {
    SGSingEngine *engine = atomic_load(&sg_engine);
    if (!engine) return;
    sg_seekTarget = target;
    sg_seekWritten = SGSingEngineReadStats(engine).written;
}

// Every 5 s while a lead is held or was: Spotify's clock against what the engine pulled and played, for the state
// Shared/Player reports and the one the lyrics read, so a phone's log says which clock Spotify keeps.
static void logClock(SGSingEngine *engine) {
    static CFAbsoluteTime last;
    static SGSingEngineStats before;
    static double rawBefore = -1;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (!engine || now - last < 5) return;
    SGSingEngineStats stats = SGSingEngineReadStats(engine);
    if (stats.lead <= 0 && stats.dropped == before.dropped && last) {
        last = now;
        return;
    }
    NSMutableString *line = [NSMutableString stringWithFormat:@"sing: clock: lead %.2f s held, %.2f s dropped", stats.lead, stats.dropped];
    double elapsed = last ? now - last : 0;
    if (elapsed > 0) {
        [line appendFormat:@"; over %.1f s Spotify's mixer gave %.2f s, %.2f s played", elapsed, (double)(stats.written - before.written) / kSGSingRate,
                           (double)(stats.played - before.played) / kSGSingRate];
    }
    SPTPlayerState *reported = SGPlayerState();
    id player = SGKaraokePlayer();
    SPTPlayerState *read = [player respondsToSelector:@selector(state)] ? [(id<SPTPlayer>)player state] : nil;
    NSArray *states = read && read != reported ? @[reported ?: (id)NSNull.null, read] : @[reported ?: (id)NSNull.null];
    for (NSUInteger i = 0; i < states.count; i++) {
        SPTPlayerState *state = states[i];
        if (![state isKindOfClass:objc_getClass("SPTPlayerState")]) continue;
        double raw = rawPosition(state), correction = SGSingLeadOf(state);
        NSDate *at = [state respondsToSelector:@selector(timestamp)] ? state.timestamp : nil;
        [line appendFormat:@"; %@ state: Spotify's position %.2f s (as of %.2f s, stamped %.2f s ago%@), %.2f s taken off", i ? @"the lyrics'" : @"the reported",
                           raw, rawAsOf(state), at ? now - at.timeIntervalSinceReferenceDate : -1, state.isPaused ? @", paused" : @"", correction];
        if (i == 0 && rawBefore >= 0 && elapsed > 0) [line appendFormat:@", moved %.2f s", raw - rawBefore];
        if (i == 0) rawBefore = raw;
        if (i == 0 && sg_seekTarget >= 0) {
            double heard = sg_seekTarget + ((double)stats.played - (double)sg_seekWritten) / kSGSingRate;
            [line appendFormat:@", heard by the last seek %.2f s (Spotify's position less that: %.2f s)", heard, raw - heard];
        }
    }
    SGLog(@"%@", line);
    last = now;
    before = stats;
}


static void flush(NSString *why) {
    SGSingEngine *engine = atomic_load(&sg_engine);
    double lead = SGSingHeldLead();
    if (!engine || lead <= 0) return;
    sg_lastFlush = CFAbsoluteTimeGetCurrent();
    SGSingEngineFlush(engine);
    SGLog(@"sing: %@, the %.1f s held ahead are dropped", why, lead);
}

static void tick(void) {
    // The Sing page gone a second ago: Sing may rest.
    updateRest();
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
        // Seen soon after it is reported, its lead is kept for as long as it stands (SGSingEngineLeadAt).
        SGSingLeadOf(player);
    }
    SGSingEngine *engine = atomic_load(&sg_engine);
    logClock(engine);
    if (state == SGSingStateSinging) sg_sangThisTrack = YES;
    if (engine && SGSingOn() && !sg_stopped && SGSingEngineGaveUp(engine)) {
        BOOL forGood = ++sg_giveUps >= kGiveUpsKept;
        sg_stopKind = forGood ? SGSingStopForGood : SGSingStopBehind;
        sg_stopped = forGood ? [NSString stringWithFormat:@"Karaoke could not keep up on this iPhone %d times in a row, so it stopped and songs play as they are. "
                                                          @"Switch Karaoke off and on, or choose another Runs on, to try again.", sg_giveUps]
                             : @"Karaoke could not keep up with this song on this iPhone, so it plays as it is. Karaoke tries again with the next song.";
        SGLog(@"sing: stopped, the vocals fell short for 8 s, %d in a row%@; %@", sg_giveUps, forGood ? @", so until switched off and on" : @"",
              SGSingStatusDetail());
        apply();
    }
    // Now and then while on, what the model costs on this iPhone.
    static CFAbsoluteTime summarized;
    if (engine && SGSingOn() && CFAbsoluteTimeGetCurrent() - summarized >= 30) {
        summarized = CFAbsoluteTimeGetCurrent();
        SGSingEngineStats stats = SGSingEngineReadStats(engine);
        SGSingSeparator *separator = SGSingLoaderSeparator();
        SGSingSeparatorStats copies = separator ? [separator stats] : (SGSingSeparatorStats){0};
        MLComputeUnits fast = SGSingLoaderFastUnits();
        NSString *fastPart = fast == MLComputeUnitsCPUOnly ? @"no faster copy"
            : [NSString stringWithFormat:@"%@ copy %@, %llu at %.0f ms", SGSingUnitsName(fast),
               @[@"not started", @"loading", @"ready", @"skipped", @"failed", @"timed out"][(NSUInteger)SGSingLoaderFastState()], copies.windows[1], copies.averageMS[1]];
        SGLog(@"sing: %@, %llu windows at %.0f ms each (1500 ms keeps up; CPU copy %llu at %.0f ms, %@, %llu redone on the CPU, the last on the %@), "
              @"lead %.2f s of %.2f s (the clock's %.2f s), %.2f s separated ahead, %llu frames dry, %.1f s dropped, %.1f s of 8 s short, %llu failures, Spotify %@, "
              @"thermal state %s, %@%@",
              SGSingStatusText(), stats.windows, stats.averageMS, copies.windows[0], copies.averageMS[0], fastPart,
              copies.fallbacks, copies.fast ? SGSingUnitsName(fast) : @"CPU", stats.lead, stats.targetLead, player ? SGSingLeadOf(player) : 0, stats.ready,
              stats.dryFrames, stats.dropped, stats.budgetSpent, stats.failures, sg_active ? @"active" : @"not active", SGSingThermalName(),
              [NSString stringWithFormat:@"Runs on %@", SGSingComputeUnitNames()[(NSUInteger)MIN(MAX(runsOn(), 0), 4)]],
              sg_spatialListening ? [NSString stringWithFormat:@", the voice %.0f degrees right", stats.voiceAngle * 180 / M_PI] : @"");
    }
    // Off, with the lead let go: nothing left to watch.
    if (!SGSingOn() && SGSingHeldLead() <= 0) {
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
    if (SGSingOn() && readRefusal()) {
        apply();
        announce();
    }
    updateSpatial();
    // Paused while not separating: Spotify is seeked back to what was heard, which drops the lead with nothing heard
    // lost, so the song resumes in step.
    SGSingEngine *engine = atomic_load(&sg_engine);
    double lead = SGSingHeldLead();
    if (state.isPaused && lead > 0.05 && !SGSingEngineSeparating(engine)) {
        double heard = state.positionAsOfTimestamp;
        if (heard >= 0) {
            flush([NSString stringWithFormat:@"paused while not separating, Spotify seeked back to %.2f s", heard]);
            SGKaraokeSeek((NSInteger)llround(heard * 1000));
        }
    }
    NSString *track = SGURIString(state.track.URI);
    BOOL another = track && sg_lastTrack && ![track isEqualToString:sg_lastTrack];
    if (another) sg_seekTarget = -1;
    if (another && sg_lastRaw >= 0 && sg_lastDuration > 0 && sg_lastDuration - sg_lastRaw > kEndSlack + kWatchEvery
        && CFAbsoluteTimeGetCurrent() - sg_lastFlush > 1) {
        flush(@"another track was played");
    }
    if (track) sg_lastTrack = track;
    if (another) {
        // A track Sing kept up with to its end clears the count of falls behind.
        if (!sg_stopped && sg_sangThisTrack) sg_giveUps = 0;
        sg_sangThisTrack = NO;
        retry(@"a new track", YES);
    }
}
@end

#pragma mark - the heat

static void readHeat(void) {
    static NSProcessInfoThermalState last;
    NSProcessInfoThermalState thermal = NSProcessInfo.processInfo.thermalState;
    BOOL cooler = thermal < last;
    last = thermal;
    // A cooler iPhone runs the model faster.
    if (cooler) retry([NSString stringWithFormat:@"the iPhone is cooler (%s)", SGSingThermalName()], NO);
    // Serious and Critical hold; Fair lets it run again.
    BOOL hot = thermal >= NSProcessInfoThermalStateSerious;
    if (hot == sg_hot) return;
    sg_hot = hot;
    SGLog(@"sing: the iPhone is %@ (thermal state %s)%@", hot ? @"hot" : @"cool again", SGSingThermalName(),
          hot && SGHidden(SGKeySingIgnoreHeat) ? @", and heat warnings are ignored" : @", the engine held");
    apply();
    announce();
}

#pragma mark - Spotify's clock and commands

%hook SPTPlayerState
- (double)positionAsOfTimestamp {
    double position = %orig;
    if (sg_rawPosition || position < 0) return position;
    double lead = SGSingLeadOf(self);
    return lead != 0 ? MAX(0, position - lead) : position;
}
%end

// The lock screen's elapsed time, when Spotify gives it its own count, which runs off what is heard by the state's
// lead. Which of the player's getters Spotify's now playing code reads is not known, so the time is moved only when it
// is nearer Spotify's own count than the heard one: one already taken through the hook above is left as it is.
%hook MPNowPlayingInfoCenter
- (void)setNowPlayingInfo:(NSDictionary *)info {
    SPTPlayerState *state = SGPlayerState();
    double lead = state ? SGSingLeadOf(state) : 0;
    NSNumber *elapsed = info[MPNowPlayingInfoPropertyElapsedPlaybackTime];
    if (fabs(lead) > 0.05 && [elapsed isKindOfClass:NSNumber.class]) {
        double raw = rawPosition(state), at = elapsed.doubleValue;
        if (raw >= 0 && fabs(at - raw) < fabs(at - (raw - lead))) {
            NSMutableDictionary *heard = [info mutableCopy];
            heard[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(MAX(0, at - lead));
            %orig(heard);
            return;
        }
    }
    %orig;
}
%end

%hook SPTEsperantoPlayer
// Each seek runs on into the last one with the creator's timestamp (seekTo: 0x1096db0c0 into seekTo:options:, that
// and seekTo:relative: into seekTo:relative:options:, that into the last, which sends the position times 1000 as
// milliseconds), so the anchor is taken there, for an absolute seek (relative 0).
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
    if (relative == 0) seekAnchor(position);
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
    sg_outputReachable = SGPlayerWatchMusicOutput(musicOutputChanged);
    if (!sg_outputReachable) SGLog(@"sing: Spotify's output cannot be watched, Sing cannot read its format");
    SGPlayerSetStage(stage);
    %init;
    SGRequireClasses(@[@"SPTPlayerState", @"SPTEsperantoPlayer"]);
    // Runs on was GPU, GPU and Neural Engine, Neural Engine (unset: Neural Engine); a choice made then is the
    // faster copy's now, under its new place in the list, and unset is Automatic.
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSNumber *before = [defaults objectForKey:SGKeySingComputeUnitsBefore];
    if (before && ![defaults objectForKey:SGKeySingComputeUnits]) {
        NSInteger was = before.integerValue;
        [defaults setInteger:was == 0 ? 2 : was == 1 ? 4 : 3 forKey:SGKeySingComputeUnits];
        [defaults removeObjectForKey:SGKeySingComputeUnitsBefore];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        static SGSingTrackWatcher *watcher;
        watcher = [SGSingTrackWatcher new];
        SGAddPlayerStateObserver(watcher);
        SGSingLoaderSetChanged(^{ loaderChanged(); });
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        // Posted on whichever thread saw the change: handed to main without waiting.
        [center addObserverForName:NSProcessInfoThermalStateDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
            dispatch_async(dispatch_get_main_queue(), ^{ readHeat(); });
        }];
        // Headphones in or out, or iOS's own spatial audio switched.
        for (NSNotificationName name in @[AVAudioSessionRouteChangeNotification, AVAudioSessionSpatialPlaybackCapabilitiesChangedNotification]) {
            // Posted on the audio session's thread: handed to main without waiting, so it cannot deadlock against main.
            [center addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (SGSingOn() && readRefusal()) {
                        apply();
                        announce();
                    }
                    updateSpatial();
                });
            }];
        }
        // A load starts only while Spotify is active, so never in a launch into the background, and the faster copy
        // runs the windows only then.
        [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            sg_active = YES;
            SGSingLoaderSetForeground(YES);
            if (SGSingOn()) apply();
        }];
        [center addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            sg_active = NO;
            SGSingLoaderSetForeground(NO);
        }];
        // Low on memory, the model goes at once, before iOS closes Spotify for it.
        [center addObserverForName:UIApplicationDidReceiveMemoryWarningNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            SGSingLoaderPurge(@"iOS warned that memory is low");
            // Over a stop for falling behind, which would load the model again with the next track whatever the memory.
            if (!SGSingOn() || (sg_stopped && sg_stopKind != SGSingStopBehind)) return;
            sg_stopKind = SGSingStopMemory;
            sg_stopped = @"Karaoke stopped to free memory, so the song plays as it is. It loads the voice model again with the next song if there is room, "
                         @"or switch Karaoke off and on.";
            apply();
            announce();
        }];
        [center addObserverForName:SGSingChangedNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
            if (SGSingModelCurrentState() != SGSingModelReady) {
                SGSingLoaderPurge(@"the voice model is gone from the iPhone");
            } else if (SGSingOn() && sg_active && !sg_resting && SGSingLoaderCurrentState() == SGSingLoaderIdle && !(sg_hot && !SGHidden(SGKeySingIgnoreHeat))) {
                // A download finishing with the mic already on loads the model.
                apply();
            }
        }];
        sg_active = UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
        SGSingLoaderSetForeground(sg_active);
        readHeat();
        readRefusal();
        if (SGSingOn()) apply();
    });
}
