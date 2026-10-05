// Sing in the simulator, end to end: the voice model downloaded by SGSingModel.m from Hugging Face and checked,
// loaded by Sing.x, and Spotify's audio chain rebuilt with real Core Audio units (a converter fed by a render
// callback, a mixer and RemoteIO, wired with MakeConnection, slices of 4096) with SpeedPitch.x and Sing.x
// compiled in. The harness is the main executable, so its AudioUnitSetProperty and AudioOutputUnitStart go
// through the rebound import slots as Spotify's do, and Sing's stage runs in Speed and pitch's chain.
//
// The converter's callback stands in for Spotify's decoder: a voice (macOS's speech, bundled by build-sim.sh)
// over synthetic chords. A mock SPTPlayerState computes -position the way Spotify's does (positionAsOfTimestamp
// messaged, disassembly at 0x1057735ec), and a mock SPTEsperantoPlayer moves the decoder on seekTo:. A render
// notify on the RemoteIO unit records what plays. The script: Sing on at the vocals' 0, play, seek, Sing off;
// each check prints a line, and what played is scored against the chords alone.
//
//     THEOS=$HOME/theos VOICE=speech.aiff ./build-sim.sh
//     xcrun simctl install <udid> build/sim/SingHarness.app
//     xcrun simctl launch --console-pty <udid> com.vojta.singharness
#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <stdatomic.h>
#import "Shared/Sing/Sing.h"

static const double kRate = 44100;
enum { kMixSeconds = 60, kRecordSeconds = 70 };

static int sg_failures;
// The vocals' checks need the model to keep up, which the simulator's Core ML (on the CPU) does not: there they
// are reported as skipped, with the time a window took.
static BOOL sg_modelKeepsUp = YES;
#define VOCALS_CHECK(ok, ...) do { if (sg_modelKeepsUp) CHECK(ok, __VA_ARGS__); else NSLog(@"[harness] skipped %@ (Sing is %@: the model is slower than the song here)", [NSString stringWithFormat:__VA_ARGS__], SGSingStatusText()); } while (0)
#define CHECK(ok, ...) do { bool _ok = (ok); if (!_ok) sg_failures++; NSLog(@"[harness] %@ %@", _ok ? @"  ok  " : @"FAILED", [NSString stringWithFormat:__VA_ARGS__]); } while (0)

#pragma mark - Spotify's player, as far as Sing reads it

// Shared/Player/PlayerState.x's, which the harness does without: no state is reported to Sing's track watcher.
NSString *SGURIString(id uri) {
    return [uri isKindOfClass:NSString.class] ? uri : nil;
}

void SGAddPlayerStateObserver(id observer) {}

id SGPlayerState(void) {
    return nil;
}

@interface SPTPlayerState : NSObject
@property (nonatomic) double positionAsOfTimestamp;
@property (nonatomic, strong) NSDate *timestamp;
@end

@implementation SPTPlayerState
- (double)playbackSpeed {
    return 1;
}
// As Spotify's: -1 kept, otherwise run on by the time since, never below 0.
- (double)position {
    double asOf = [self positionAsOfTimestamp];
    if (asOf == -1) return asOf;
    return MAX(0, asOf - self.timestamp.timeIntervalSinceNow * [self playbackSpeed]);
}
@end

#pragma mark - the decoder

static float *sg_left, *sg_right, *sg_chordsLeft, *sg_chordsRight;
static size_t sg_mixFrames;
static atomic_uint_fast64_t sg_decoded;   // frames handed over
static atomic_uint_fast64_t sg_readAt;    // where in the mix the next one comes from

static OSStatus decoder(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timestamp, UInt32 bus,
                        UInt32 frames, AudioBufferList *data) {
    uint64_t at = atomic_fetch_add(&sg_readAt, frames);
    atomic_fetch_add(&sg_decoded, frames);
    float *left = data->mBuffers[0].mData, *right = data->mNumberBuffers > 1 ? data->mBuffers[1].mData : left;
    for (UInt32 i = 0; i < frames; i++) {
        size_t index = (size_t)((at + i) % sg_mixFrames);
        left[i] = sg_left[index];
        right[i] = sg_right[index];
    }
    return noErr;
}

@interface SPTEsperantoPlayer : NSObject
@end

static id sg_seekResult;

// Each command returns an object of Spotify's, which the hook must hand back.
@implementation SPTEsperantoPlayer
- (id)seekTo:(double)position {
    atomic_store(&sg_readAt, (uint64_t)(position * kRate));
    return sg_seekResult;
}
- (id)seekTo:(double)position relative:(long long)relative { return sg_seekResult; }
- (id)seekTo:(double)position options:(id)options { return [self seekTo:position]; }
- (id)seekTo:(double)position relative:(long long)relative options:(id)options { return sg_seekResult; }
- (id)seekTo:(double)position relative:(long long)relative options:(id)options creatorTimestampPositionMs:(double)creator { return sg_seekResult; }
- (id)skipToNextTrackWithOptions:(id)options { return sg_seekResult; }
- (id)skipToPreviousTrackWithOptions:(id)options { return sg_seekResult; }
- (id)skipToNextTrackWithOptions:(id)options track:(id)track { return sg_seekResult; }
- (id)skipToPreviousTrackWithOptions:(id)options track:(id)track { return sg_seekResult; }
- (id)stop { return sg_seekResult; }
@end

#pragma mark - what plays

static float *sg_heardLeft, *sg_heardRight;
static size_t sg_heardCapacity;
static atomic_uint_fast64_t sg_heard;
static double sg_hardwareRate;

static OSStatus record(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timestamp, UInt32 bus,
                       UInt32 frames, AudioBufferList *data) {
    if (!(*flags & kAudioUnitRenderAction_PostRender) || bus != 0 || data->mNumberBuffers < 2) return noErr;
    uint64_t at = atomic_load(&sg_heard);
    for (UInt32 i = 0; i < frames && at + i < sg_heardCapacity; i++) {
        sg_heardLeft[at + i] = ((float *)data->mBuffers[0].mData)[i];
        sg_heardRight[at + i] = ((float *)data->mBuffers[1].mData)[i];
    }
    atomic_store(&sg_heard, at + frames);
    return noErr;
}

#pragma mark - the mix

static void makeMix(void) {
    sg_mixFrames = (size_t)(kMixSeconds * kRate);
    sg_left = calloc(sg_mixFrames, sizeof(float));
    sg_right = calloc(sg_mixFrames, sizeof(float));
    sg_chordsLeft = calloc(sg_mixFrames, sizeof(float));
    sg_chordsRight = calloc(sg_mixFrames, sizeof(float));
    float *voice = calloc(sg_mixFrames, sizeof(float));
    size_t voiceFrames = 0;
    NSURL *url = [NSBundle.mainBundle URLForResource:@"voice" withExtension:@"aiff"];
    ExtAudioFileRef file;
    if (url && !ExtAudioFileOpenURL((__bridge CFURLRef)url, &file)) {
        AudioStreamBasicDescription format = {kRate, kAudioFormatLinearPCM, kAudioFormatFlagsNativeFloatPacked, 4, 1, 4, 1, 32, 0};
        ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, sizeof format, &format);
        while (voiceFrames < sg_mixFrames) {
            UInt32 frames = (UInt32)MIN((size_t)8192, sg_mixFrames - voiceFrames);
            AudioBufferList list = {1, {{1, frames * 4, voice + voiceFrames}}};
            if (ExtAudioFileRead(file, &frames, &list) || !frames) break;
            voiceFrames += frames;
        }
        ExtAudioFileDispose(file);
    }
    NSLog(@"[harness] the voice is %.1f s long", voiceFrames / kRate);
    static const double roots[] = {130.81, 174.61, 196.00, 110.00}, ratios[] = {1, 1.26, 1.5, 2};
    size_t beat = (size_t)kRate / 2;
    for (size_t i = 0; i < sg_mixFrames; i++) {
        size_t bar = i / (beat * 4), within = i % beat;
        double root = roots[bar % 4], env = exp(-3.0 * within / beat), t = i / kRate, l = 0, r = 0;
        for (int n = 0; n < 4; n++) {
            double f = root * ratios[n], tone = sin(2 * M_PI * f * t) + 0.4 * sin(4 * M_PI * f * t) + 0.2 * sin(6 * M_PI * f * t);
            l += tone * (n % 2 ? 0.6 : 1.0);
            r += tone * (n % 2 ? 1.0 : 0.6);
        }
        sg_chordsLeft[i] = (float)(0.06 * env * l);
        sg_chordsRight[i] = (float)(0.06 * env * r);
        // The voice over and over, a second apart, from a second in.
        size_t from = i >= (size_t)kRate && voiceFrames ? (i - (size_t)kRate) % (voiceFrames + (size_t)kRate) : SIZE_MAX;
        float v = from < voiceFrames ? 0.5f * voice[from] : 0;
        sg_left[i] = sg_chordsLeft[i] + v;
        sg_right[i] = sg_chordsRight[i] + v;
    }
    free(voice);
}

// What played, at the hardware's rate, brought to 44.1 kHz.
static NSArray<NSData *> *heardAt44k(size_t *frames) {
    size_t count = MIN((size_t)atomic_load(&sg_heard), sg_heardCapacity);
    AVAudioFormat *from = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:sg_hardwareRate channels:2 interleaved:NO];
    AVAudioFormat *to = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:kRate channels:2 interleaved:NO];
    AVAudioPCMBuffer *input = [[AVAudioPCMBuffer alloc] initWithPCMFormat:from frameCapacity:(AVAudioFrameCount)count];
    memcpy(input.floatChannelData[0], sg_heardLeft, count * sizeof(float));
    memcpy(input.floatChannelData[1], sg_heardRight, count * sizeof(float));
    input.frameLength = (AVAudioFrameCount)count;
    AVAudioConverter *converter = [[AVAudioConverter alloc] initFromFormat:from toFormat:to];
    converter.sampleRateConverterQuality = AVAudioQualityMax;
    AVAudioPCMBuffer *output = [[AVAudioPCMBuffer alloc] initWithPCMFormat:to frameCapacity:(AVAudioFrameCount)(count * kRate / sg_hardwareRate + 4096)];
    __block BOOL given = NO;
    [converter convertToBuffer:output error:nil withInputFromBlock:^AVAudioBuffer *(AVAudioPacketCount packets, AVAudioConverterInputStatus *status) {
        if (given) {
            *status = AVAudioConverterInputStatus_EndOfStream;
            return nil;
        }
        given = YES;
        *status = AVAudioConverterInputStatus_HaveData;
        return input;
    }];
    *frames = output.frameLength;
    return @[[NSData dataWithBytes:output.floatChannelData[0] length:output.frameLength * sizeof(float)],
             [NSData dataWithBytes:output.floatChannelData[1] length:output.frameLength * sizeof(float)]];
}

static double snr(const float *truthL, const float *truthR, const float *left, const float *right, size_t from, size_t to) {
    double signal = 0, noise = 0;
    for (size_t i = from; i < to; i++) {
        signal += truthL[i] * truthL[i] + truthR[i] * truthR[i];
        double l = left[i] - truthL[i], r = right[i] - truthR[i];
        noise += l * l + r * r;
    }
    return 10 * log10(signal / fmax(noise, 1e-20));
}

#pragma mark - the app

static AudioUnit make(OSType type, OSType subType) {
    AudioComponentDescription description = {type, subType, kAudioUnitManufacturer_Apple, 0, 0};
    AudioUnit unit = NULL;
    AudioComponentInstanceNew(AudioComponentFindNext(NULL, &description), &unit);
    return unit;
}

static void check(OSStatus status, const char *what) {
    if (status) NSLog(@"[harness] %s failed: %d", what, (int)status);
}

@interface SGHarnessDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation SGHarnessDelegate {
    AudioUnit _output;
    CFTimeInterval _startedAt;
    uint64_t _lastDecoded;
    CFTimeInterval _lastAt;
    SPTPlayerState *_state;
    double _seekLead;
}

- (void)startChain {
    [AVAudioSession.sharedInstance setCategory:AVAudioSessionCategoryPlayback error:nil];
    [AVAudioSession.sharedInstance setActive:YES error:nil];
    AudioUnit converter = make(kAudioUnitType_FormatConverter, kAudioUnitSubType_AUConverter);
    AudioUnit mixer = make(kAudioUnitType_Mixer, kAudioUnitSubType_MultiChannelMixer);
    _output = make(kAudioUnitType_Output, kAudioUnitSubType_RemoteIO);
    AURenderCallbackStruct callback = {decoder, NULL};
    check(AudioUnitSetProperty(converter, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof callback), "callback");
    AudioUnitConnection toMixer = {converter, 0, 0}, toOutput = {mixer, 0, 0};
    check(AudioUnitSetProperty(mixer, kAudioUnitProperty_MakeConnection, kAudioUnitScope_Input, 0, &toMixer, sizeof toMixer), "connect mixer");
    check(AudioUnitSetProperty(_output, kAudioUnitProperty_MakeConnection, kAudioUnitScope_Input, 0, &toOutput, sizeof toOutput), "connect output");
    AudioStreamBasicDescription format = {kRate, kAudioFormatLinearPCM, kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved, 4, 1, 4, 2, 32, 0};
    check(AudioUnitSetProperty(converter, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, sizeof format), "converter in");
    check(AudioUnitSetProperty(converter, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, sizeof format), "converter out");
    check(AudioUnitSetProperty(mixer, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, sizeof format), "mixer in");
    check(AudioUnitSetProperty(mixer, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, sizeof format), "mixer out");
    check(AudioUnitSetProperty(_output, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, sizeof format), "output in");
    UInt32 slice = 4096;
    AudioUnit units[] = {converter, mixer, _output};
    for (int i = 0; i < 3; i++) check(AudioUnitSetProperty(units[i], kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &slice, sizeof slice), "slice");
    for (int i = 0; i < 3; i++) check(AudioUnitInitialize(units[i]), "initialize");
    AudioStreamBasicDescription hardware = {0};
    UInt32 size = sizeof hardware;
    AudioUnitGetProperty(_output, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &hardware, &size);
    sg_hardwareRate = hardware.mSampleRate;
    sg_heardCapacity = (size_t)(kRecordSeconds * sg_hardwareRate);
    sg_heardLeft = calloc(sg_heardCapacity, sizeof(float));
    sg_heardRight = calloc(sg_heardCapacity, sizeof(float));
    check(AudioOutputUnitStart(_output), "start");
    check(AudioUnitAddRenderNotify(_output, record, NULL), "record");
    _startedAt = CACurrentMediaTime();
    _lastAt = _startedAt;
    NSLog(@"[harness] the chain runs, the hardware at %.0f Hz", sg_hardwareRate);
}

- (void)after:(double)seconds do:(void (^)(void))block {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), block);
}

// The player reporting what the decoder has handed over, as Spotify's does now and then.
- (void)playerReports {
    _state = [SPTPlayerState new];
    _state.positionAsOfTimestamp = atomic_load(&sg_readAt) / kRate;
    _state.timestamp = [NSDate date];
}

// What is heard now, in seconds of the mix: what the output played, less what a seek skipped.
- (double)heardContent {
    return atomic_load(&sg_heard) / sg_hardwareRate;
}

- (void)report {
    CFTimeInterval now = CACurrentMediaTime();
    uint64_t decoded = atomic_load(&sg_decoded);
    [self playerReports];
    NSLog(@"[harness] %5.1f s  %-22@ decoder %.2fx  position %.2f s, Spotify's own %.2f s  (%.2f s ahead of what plays)",
          now - _startedAt, SGSingStatusText(), (decoded - _lastDecoded) / kRate / (now - _lastAt), _state.position,
          atomic_load(&sg_readAt) / kRate, atomic_load(&sg_readAt) / kRate - _state.position);
    _lastDecoded = decoded;
    _lastAt = now;
}

- (void)waitFor:(BOOL (^)(void))condition every:(double)seconds then:(void (^)(void))then {
    if (condition()) {
        then();
        return;
    }
    [self after:seconds do:^{ [self waitFor:condition every:seconds then:then]; }];
}

- (void)play {
    // Played straight through until the first seek: the position Spotify shows against what is heard.
    for (int s = 1; s <= 46; s++) [self after:s do:^{ [self report]; }];
    [self after:14 do:^{
        double heard = [self heardContent], position = self->_state.position;
        [self playerReports];
        position = self->_state.position;
        sg_modelKeepsUp = SGSingCurrentState() != SGSingStateBehind && SGSingCurrentState() != SGSingStateBuffering;
        VOCALS_CHECK(SGSingCurrentState() == SGSingStateSinging, @"Sing is on with the vocals down at 14 s (%@)", SGSingStatusText());
        CHECK(fabs(position - heard) < 0.15, @"the position Spotify shows, %.2f s, is what is heard, %.2f s, not what was decoded, %.2f s",
              position, heard, atomic_load(&sg_readAt) / kRate);
    }];
    [self after:20 do:^{
        double lead = atomic_load(&sg_readAt) / kRate - self->_state.position;
        self->_seekLead = lead;
        id result = [[SPTEsperantoPlayer new] seekTo:5];
        CHECK(result == sg_seekResult, @"a seek hands Spotify back the result of its seek");
    }];
    [self after:20.5 do:^{
        [self playerReports];
        double ahead = atomic_load(&sg_readAt) / kRate - self->_state.position;
        CHECK(ahead < 1.2, @"the seek dropped the %.1f s held ahead: %.2f s ahead half a second later", self->_seekLead, ahead);
    }];
    [self after:30 do:^{
        VOCALS_CHECK(SGSingCurrentState() == SGSingStateSinging, @"ten seconds after the seek the vocals are down again (%@)", SGSingStatusText());
        SGSetSingOn(NO);
    }];
    [self after:45 do:^{
        [self playerReports];
        double ahead = atomic_load(&sg_readAt) / kRate - self->_state.position;
        CHECK(ahead < 0.05 && SGSingCurrentState() == SGSingStateOff, @"switched off, the lead is given back (%.2f s) and Sing is %@", ahead, SGSingStatusText());
        [self score];
        NSLog(@"[harness] %@", sg_failures ? @"FAILED" : @"all passed");
        exit(sg_failures ? 1 : 0);
    }];
}

// What played from 6 s to 19 s against the chords alone, beside the mix's own score. Before the seek what plays
// is the mix in order, so the two line up but for the resampler's delay, found on the first second (dry).
- (void)score {
    size_t frames;
    NSArray<NSData *> *heard = heardAt44k(&frames);
    const float *left = heard[0].bytes, *right = heard[1].bytes;
    size_t from = (size_t)(6 * kRate), to = (size_t)(19 * kRate);
    if (frames < to + 1000) {
        CHECK(NO, @"enough was heard to score (%.1f s)", frames / kRate);
        return;
    }
    int best = 0;
    double bestScore = -INFINITY;
    for (int lag = -64; lag <= 64; lag++) {
        double dot = 0;
        for (size_t i = (size_t)kRate / 4; i < (size_t)kRate; i++) dot += left[i + lag] * sg_left[i];
        if (dot > bestScore) bestScore = dot, best = lag;
    }
    double dry = snr(sg_left, sg_right, left + best, right + best, (size_t)(kRate / 4), (size_t)kRate);
    NSLog(@"[harness] what plays lags the mix by %d frames after resampling; the first second matches the mix to %.1f dB", best, dry);
    double karaoke = snr(sg_chordsLeft, sg_chordsRight, left + best, right + best, from, to);
    double mix = snr(sg_chordsLeft, sg_chordsRight, sg_left, sg_right, from, to);
    VOCALS_CHECK(karaoke > mix + 15, @"from 6 s to 19 s what plays scores %.1f dB against the chords alone, the mix %.1f dB", karaoke, mix);
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [UIViewController new];
    sg_seekResult = [NSObject new];
    makeMix();
    NSLog(@"[harness] Sing: %@ (%@)", SGSingStatusText(), SGSingMissing() ?: @"nothing missing");
    CFTimeInterval began = CACurrentMediaTime();
    if (SGSingModelCurrentState() != SGSingModelReady) SGSingDownloadModel();
    __block CFTimeInterval logged = 0;
    [self waitFor:^BOOL {
        if (CACurrentMediaTime() - logged > 5) {
            logged = CACurrentMediaTime();
            NSLog(@"[harness] %@", SGSingStatusText());
        }
        return SGSingModelCurrentState() != SGSingModelDownloading;
    } every:0.5 then:^{
        CHECK(SGSingModelCurrentState() == SGSingModelReady, @"the voice model is on the phone, checked (%@, %.0f s)", SGSingModelError() ?: @"no error",
              CACurrentMediaTime() - began);
        if (SGSingModelCurrentState() != SGSingModelReady) exit(1);
        SGSetSingLevel(0);
        CFTimeInterval loading = CACurrentMediaTime();
        SGSetSingOn(YES);
        [self waitFor:^BOOL { return SGSingCurrentState() != SGSingStatePreparing; } every:0.25 then:^{
            CHECK(SGSingCurrentState() == SGSingStateWaiting, @"the model loads in %.1f s, and Sing waits for Spotify (%@)", CACurrentMediaTime() - loading,
                  SGSingStatusText());
            [self startChain];
            [self play];
        }];
    }];
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(SGHarnessDelegate.class));
    }
}
