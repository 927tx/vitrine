// Runs Sing's separator and engine (tweak/Sources/Shared/Sing) on the Mac the way the tweak runs them. Each
// check prints a line.
//
// - the STFT: a sine's peak bin at the size torch.stft gives it (amplitude times the window's sum over two), and
//   noise through the STFT and back unchanged;
// - the model: loaded from a separator.mlmodelc folder at the compute units asked for, the time a window takes,
//   and a voice mixed over chords taken apart: the vocals it finds against the voice, beside the mix's own score;
// - the engine: Spotify's mixer stood in for by the mix, pulled through SGSingEngineRender in IO buffers on a
//   thread that keeps real time, while the engine's worker separates ahead: the lead it builds, every frame
//   out in order, the vocals level applied, a flush, the lead given back when Sing is switched off, and
//   no allocation on the render thread.
//
//     ./build.sh && build/sing <separator.mlmodelc> <voice> <out dir> [all|cpu|gpu|ane]
#import <Foundation/Foundation.h>
#import <Accelerate/Accelerate.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreML/CoreML.h>
#import <pthread.h>
#import <stdatomic.h>
#import "Shared/Sing/SGSingSeparator.h"
#import "Shared/Sing/SGSingEngine.h"

static int sg_failures;
static NSString *sg_outDir;

#define CHECK(ok, ...) do { bool _ok = (ok); if (!_ok) sg_failures++; printf("%s ", _ok ? "  ok  " : "FAILED"); printf(__VA_ARGS__); printf("\n"); } while (0)

#pragma mark - audio

typedef struct {
    float *left, *right;
    size_t frames;
} Audio;

static Audio makeAudio(size_t frames) {
    return (Audio){calloc(frames, sizeof(float)), calloc(frames, sizeof(float)), frames};
}

static AudioStreamBasicDescription floatFormat(double rate, UInt32 channels, bool interleaved) {
    UInt32 bytes = interleaved ? 4 * channels : 4;
    return (AudioStreamBasicDescription){rate, kAudioFormatLinearPCM,
        kAudioFormatFlagsNativeFloatPacked | (interleaved ? 0 : kAudioFormatFlagIsNonInterleaved), bytes, 1, bytes, channels, 32, 0};
}

static Audio readAudio(NSString *path) {
    ExtAudioFileRef file;
    if (ExtAudioFileOpenURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], &file)) {
        printf("cannot open %s\n", path.UTF8String);
        exit(1);
    }
    AudioStreamBasicDescription format = floatFormat(kSGSingRate, 2, false);
    ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, sizeof format, &format);
    Audio audio = makeAudio(kSGSingRate * 60);
    size_t done = 0;
    while (done < audio.frames) {
        UInt32 frames = (UInt32)MIN((size_t)8192, audio.frames - done);
        struct { AudioBufferList list; AudioBuffer second; } buffers = {{2, {{1, frames * 4, audio.left + done}}}, {1, frames * 4, audio.right + done}};
        if (ExtAudioFileRead(file, &frames, &buffers.list) || !frames) break;
        done += frames;
    }
    ExtAudioFileDispose(file);
    audio.frames = done;
    return audio;
}

static void writeWAV(NSString *name, Audio audio) {
    NSString *path = [sg_outDir stringByAppendingPathComponent:name];
    AudioStreamBasicDescription stored = floatFormat(kSGSingRate, 2, true);
    ExtAudioFileRef file;
    if (ExtAudioFileCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], kAudioFileWAVEType, &stored, NULL, kAudioFileFlags_EraseFile, &file)) return;
    AudioStreamBasicDescription client = floatFormat(kSGSingRate, 2, false);
    ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, sizeof client, &client);
    struct { AudioBufferList list; AudioBuffer second; } buffers = {{2, {{1, (UInt32)audio.frames * 4, audio.left}}}, {1, (UInt32)audio.frames * 4, audio.right}};
    ExtAudioFileWrite(file, (UInt32)audio.frames, &buffers.list);
    ExtAudioFileDispose(file);
}

// Signal to error in dB of `estimate` against `truth` over [from, to).
static double snr(Audio truth, Audio estimate, size_t from, size_t to) {
    double signal = 0, noise = 0;
    for (size_t i = from; i < to; i++) {
        double l = truth.left[i], r = truth.right[i];
        double el = estimate.left[i] - l, er = estimate.right[i] - r;
        signal += l * l + r * r;
        noise += el * el + er * er;
    }
    return 10 * log10(signal / fmax(noise, 1e-20));
}

// Block chords with a decay, a note every half second, in a fifth of the stereo field each side.
static Audio chords(size_t frames) {
    Audio audio = makeAudio(frames);
    static const double roots[] = {130.81, 174.61, 196.00, 110.00};
    size_t beat = kSGSingRate / 2;
    for (size_t i = 0; i < frames; i++) {
        size_t bar = i / (beat * 4), within = i % beat;
        double root = roots[bar % 4], env = exp(-3.0 * within / beat), t = (double)i / kSGSingRate;
        double l = 0, r = 0;
        static const double ratios[] = {1, 1.26, 1.5, 2};
        for (int n = 0; n < 4; n++) {
            double f = root * ratios[n];
            double tone = sin(2 * M_PI * f * t) + 0.4 * sin(4 * M_PI * f * t) + 0.2 * sin(6 * M_PI * f * t);
            l += tone * (n % 2 ? 0.6 : 1.0);
            r += tone * (n % 2 ? 1.0 : 0.6);
        }
        audio.left[i] = (float)(0.06 * env * l);
        audio.right[i] = (float)(0.06 * env * r);
    }
    return audio;
}

#pragma mark - the STFT

static void checkSTFT(void) {
    SGSingSeparator *stft = [[SGSingSeparator alloc] initWithModel:nil];
    float *spectrum = calloc(kSGSingSpectrumFloats, sizeof(float));
    Audio in = makeAudio(kSGSingWindowFrames), out = makeAudio(kSGSingWindowFrames);
    int bin = 100;
    double frequency = bin * (double)kSGSingRate / kSGSingFFT;
    for (int i = 0; i < kSGSingWindowFrames; i++) {
        in.left[i] = (float)(0.5 * cos(2 * M_PI * frequency * i / kSGSingRate));
        in.right[i] = (float)(0.25 * cos(2 * M_PI * frequency * i / kSGSingRate));
    }
    [stft analyzeLeft:in.left right:in.right into:spectrum];
    int frame = 100;
    const float *left = spectrum + ((size_t)(2 * bin) * kSGSingSTFTFrames + frame) * 2;
    const float *right = spectrum + ((size_t)(2 * bin + 1) * kSGSingSTFTFrames + frame) * 2;
    double magnitude = hypot(left[0], left[1]), rightMagnitude = hypot(right[0], right[1]);
    // The periodic Hann window of 2048 sums to 1024, so a cosine of amplitude A peaks at A * 1024 / 2.
    CHECK(fabs(magnitude - 256) < 1 && fabs(rightMagnitude - 128) < 0.5, "a 0.5 cosine on bin %d peaks at %.2f (256 expected), 0.25 at %.2f in the right channel's slot",
          bin, magnitude, rightMagnitude);
    srand48(7);
    for (int i = 0; i < kSGSingWindowFrames; i++) {
        in.left[i] = (float)(drand48() * 2 - 1) * 0.5f;
        in.right[i] = (float)(0.3 * sin(i * 0.01) + (drand48() - 0.5) * 0.1);
    }
    [stft analyzeLeft:in.left right:in.right into:spectrum];
    [stft synthesize:spectrum left:out.left right:out.right];
    float worst = 0;
    for (int i = 0; i < kSGSingWindowFrames; i++) worst = fmaxf(worst, fmaxf(fabsf(out.left[i] - in.left[i]), fabsf(out.right[i] - in.right[i])));
    CHECK(worst < 1e-5, "noise through the STFT and back, edges included, within %.2g", worst);
    free(spectrum);
}

#pragma mark - the model

static MLComputeUnits unitsNamed(NSString *name) {
    if ([name isEqualToString:@"cpu"]) return MLComputeUnitsCPUOnly;
    if ([name isEqualToString:@"gpu"]) return MLComputeUnitsCPUAndGPU;
    if ([name isEqualToString:@"ane"]) return MLComputeUnitsCPUAndNeuralEngine;
    return MLComputeUnitsAll;
}

static double now(void) {
    return CFAbsoluteTimeGetCurrent();
}

// The offline pass the engine makes as it plays: windows a hop apart, their overlaps crossfaded.
static Audio separateOffline(SGSingSeparator *separator, Audio mix, double *slowest, double *average) {
    Audio vocals = makeAudio(mix.frames);
    Audio window = makeAudio(kSGSingWindowFrames);
    int count = 0;
    double total = 0;
    *slowest = 0;
    size_t previousEnd = 0;
    for (size_t start = 0; start + kSGSingWindowFrames <= mix.frames; start += kSGSingEngineHop) {
        double began = now();
        NSError *error;
        if (![separator separateLeft:mix.left + start right:mix.right + start vocalsLeft:window.left vocalsRight:window.right error:&error]) {
            printf("the model failed: %s\n", error.localizedDescription.UTF8String);
            exit(1);
        }
        double took = now() - began;
        total += took;
        *slowest = fmax(*slowest, took);
        count++;
        for (size_t i = 0; i < kSGSingWindowFrames; i++) {
            size_t p = start + i;
            float a = p < previousEnd ? (float)(p - start) / (float)(previousEnd - start) : 1;
            vocals.left[p] = vocals.left[p] * (1 - a) + window.left[i] * a;
            vocals.right[p] = vocals.right[p] * (1 - a) + window.right[i] * a;
        }
        previousEnd = start + kSGSingWindowFrames;
    }
    *average = total / count;
    return vocals;
}

static MLModel *loadModel(NSString *path, NSString *units) {
    MLModelConfiguration *configuration = [MLModelConfiguration new];
    configuration.computeUnits = unitsNamed(units);
    double began = now();
    NSError *error;
    MLModel *model = [MLModel modelWithContentsOfURL:[NSURL fileURLWithPath:path] configuration:configuration error:&error];
    CHECK(model != nil, "the model loads (%s compute units) in %.1f s%s%s", units.UTF8String, now() - began, error ? ": " : "",
          error.localizedDescription.UTF8String ?: "");
    if (!model) exit(1);
    MLFeatureDescription *input = model.modelDescription.inputDescriptionsByName[@"spectrum"];
    MLFeatureDescription *output = model.modelDescription.outputDescriptionsByName[@"vocals_spectrum"];
    CHECK([input.multiArrayConstraint.shape isEqualToArray:(@[@1, @2050, @201, @2])] && [output.multiArrayConstraint.shape isEqualToArray:(@[@1, @2050, @201, @2])],
          "its spectrum and vocals_spectrum are [1, 2050, 201, 2]");
    return model;
}

// Which device Core ML means to run each operation on, counted, where the OS can tell.
static void describePlan(NSString *path, NSString *units) {
    if (@available(macOS 14.4, *)) {
        MLModelConfiguration *configuration = [MLModelConfiguration new];
        configuration.computeUnits = unitsNamed(units);
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        [MLComputePlan loadContentsOfURL:[NSURL fileURLWithPath:path] configuration:configuration completionHandler:^(MLComputePlan *plan, NSError *error) {
            NSMutableDictionary<NSString *, NSNumber *> *counts = [NSMutableDictionary dictionary];
            MLModelStructureProgramFunction *main = plan.modelStructure.program.functions[@"main"];
            for (MLModelStructureProgramOperation *operation in main.block.operations) {
                MLComputePlanDeviceUsage *usage = [plan computeDeviceUsageForMLProgramOperation:operation];
                if (!usage) continue;
                id<MLComputeDeviceProtocol> device = usage.preferredComputeDevice;
                NSString *name = [device isKindOfClass:MLNeuralEngineComputeDevice.class] ? @"Neural Engine"
                               : [device isKindOfClass:MLGPUComputeDevice.class] ? @"GPU" : @"CPU";
                counts[name] = @(counts[name].intValue + 1);
            }
            printf("  info  the plan at %s: %s\n", units.UTF8String, counts.description.UTF8String);
            dispatch_semaphore_signal(done);
        }];
        dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    }
}

#pragma mark - the engine

typedef struct {
    Audio source;
    size_t pulled;
} Source;

static OSStatus pullSource(void *context, UInt32 frames, float *left, float *right) {
    Source *source = context;
    for (UInt32 i = 0; i < frames; i++) {
        size_t at = source->pulled + i;
        left[i] = at < source->source.frames ? source->source.left[at] : 0;
        right[i] = at < source->source.frames ? source->source.right[at] : 0;
    }
    source->pulled += frames;
    return noErr;
}

typedef void(malloc_logger_t)(uint32_t type, uintptr_t arg1, uintptr_t arg2, uintptr_t arg3, uintptr_t result, uint32_t skip);
extern malloc_logger_t *malloc_logger;
static pthread_t sg_renderThread;
static atomic_bool sg_inRender;
static atomic_uint sg_renderAllocations;

static void countAllocation(uint32_t type, uintptr_t a, uintptr_t b, uintptr_t c, uintptr_t result, uint32_t skip) {
    if (atomic_load_explicit(&sg_inRender, memory_order_relaxed) && pthread_equal(pthread_self(), sg_renderThread)) {
        atomic_fetch_add_explicit(&sg_renderAllocations, 1, memory_order_relaxed);
    }
}

// Plays `mix` through the engine in real time, in buffers of `slice`; `script` is called once a buffer with the
// seconds played, for the test to switch things.
static Audio play(SGSingEngine *engine, Audio mix, Source *source, UInt32 slice, double seconds, void (^script)(double played)) {
    Audio out = makeAudio((size_t)(seconds * kSGSingRate));
    sg_renderThread = pthread_self();
    double began = now();
    for (size_t done = 0; done + slice <= out.frames; done += slice) {
        script((double)done / kSGSingRate);
        atomic_store(&sg_inRender, true);
        SGSingEngineRender(engine, slice, out.left + done, out.right + done, pullSource, source);
        atomic_store(&sg_inRender, false);
        double due = began + (double)(done + slice) / kSGSingRate;
        double wait = due - now();
        if (wait > 0) usleep((useconds_t)(wait * 1e6));
    }
    return out;
}

static void checkEngine(SGSingSeparator *separator, Audio mix, Audio voice, Audio offlineVocals) {
    SGSingEngine *engine = SGSingEngineCreate();
    SGSingEngineSetSeparator(engine, separator);
    SGSingEngineSetLevel(engine, 0);
    Source source = {mix, 0};
    // On from the first buffer, so the engine's windows fall where the offline pass's do; off at 17 s.
    SGSingEngineSetOn(engine, true);
    __block double leadAtOn = 0, leadAtOff = 0, leadMax = 0;
    malloc_logger = countAllocation;
    Audio out = play(engine, mix, &source, 1024, fmin(mix.frames / (double)kSGSingRate, 28), ^(double played) {
        double lead = SGSingEngineLead(engine);
        leadMax = fmax(leadMax, lead);
        if (played >= 12 && leadAtOn == 0) leadAtOn = lead;
        if (played >= 17 && SGSingEngineOn(engine)) SGSingEngineSetOn(engine, false);
        if (played >= 27) leadAtOff = lead;
    });
    malloc_logger = NULL;
    CHECK(atomic_load(&sg_renderAllocations) == 0, "no allocation on the render thread (%u)", atomic_load(&sg_renderAllocations));
    SGSingEngineStats stats = SGSingEngineReadStats(engine);
    printf("  info  lead at 12 s %.2f s (at most %.2f s, target %.2f s), %llu windows at %.0f ms average, %llu frames played dry while on\n",
           leadAtOn, leadMax, stats.targetLead, stats.windows, stats.averageMS, stats.dryFrames);
    CHECK(leadAtOn > 2 && leadAtOn < 7, "with Sing on the engine pulls ahead of what plays (%.2f s)", leadAtOn);
    CHECK(leadAtOff < 0.05, "switched off it gives the lead back (%.3f s left)", leadAtOff);
    // What plays is the mixer's frames in order, from 6 s to 16 s the mix less the vocals the offline pass finds,
    // with the vocals at 0.
    size_t from = 6 * kSGSingRate, to = 16 * kSGSingRate;
    Audio expected = makeAudio(out.frames), instrumental = makeAudio(out.frames);
    for (size_t i = 0; i < out.frames; i++) {
        expected.left[i] = mix.left[i] - offlineVocals.left[i];
        expected.right[i] = mix.right[i] - offlineVocals.right[i];
        instrumental.left[i] = mix.left[i] - voice.left[i];
        instrumental.right[i] = mix.right[i] - voice.right[i];
    }
    double first = 0;
    for (size_t i = 0; i < kSGSingRate; i++) first = fmax(first, fabs(out.left[i] - mix.left[i]) + fabs(out.right[i] - mix.right[i]));
    CHECK(first == 0, "while the lead fills the mix plays dry (%.2g)", first);
    double match = snr(expected, out, from, to);
    CHECK(match > 25, "then what plays is the mix less the vocals the offline pass finds (%.1f dB)", match);
    printf("  info  the karaoke against the true instrumental: %.1f dB; the mix's own: %.1f dB\n", snr(instrumental, out, from, to), snr(instrumental, mix, from, to));
    double after = 0;
    size_t firstOff = 0;
    for (size_t i = 26 * kSGSingRate; i < out.frames / 1024 * 1024; i++) {
        double d = fabs(out.left[i] - mix.left[i]) + fabs(out.right[i] - mix.right[i]);
        if (d > 1e-6 && !firstOff) firstOff = i;
        after = fmax(after, d);
    }
    if (firstOff) printf("  info  first difference at %.4f s: out %g, mix %g, mix a frame on %g\n", firstOff / (double)kSGSingRate, out.left[firstOff], mix.left[firstOff], mix.left[firstOff + 1]);
    CHECK(after < 1e-6, "off again, the mix plays on where it was (%.2g)", after);
    writeWAV(@"engine.wav", out);

    // The level: at 2 only the vocals play.
    SGSingEngine *loud = SGSingEngineCreate();
    SGSingEngineSetSeparator(loud, separator);
    SGSingEngineSetLevel(loud, 2);
    SGSingEngineSetOn(loud, true);
    Source third = {mix, 0};
    Audio alone = play(loud, mix, &third, 1024, 10, ^(double played) {});
    double vocalsOnly = snr(offlineVocals, alone, 6 * kSGSingRate, 9 * kSGSingRate);
    CHECK(vocalsOnly > 30, "at the top of the slider the vocals play alone (%.1f dB against the offline vocals)", vocalsOnly);
    SGSingEngineDestroy(loud);

    // A flush drops what was pulled ahead: the next frame out is the one the mixer hands over next.
    SGSingEngine *flushing = SGSingEngineCreate();
    SGSingEngineSetSeparator(flushing, separator);
    Source second = {mix, 0}, *secondSource = &second;
    __block size_t pulledAtFlush = 0;
    __block bool flushed = false;
    Audio afterFlush = play(flushing, mix, &second, 512, 8, ^(double played) {
        if (!SGSingEngineOn(flushing)) SGSingEngineSetOn(flushing, true);
        if (played >= 5 && !flushed) {
            flushed = true;
            pulledAtFlush = secondSource->pulled;
            SGSingEngineFlush(flushing);
        }
    });
    size_t at = (size_t)(5 * kSGSingRate / 512 + 1) * 512;
    CHECK(fabsf(afterFlush.left[at] - mix.left[pulledAtFlush]) < 1e-6 && fabsf(afterFlush.left[at + 100] - mix.left[pulledAtFlush + 100]) < 1e-6,
          "after a flush the mixer's next frame plays next (%.0f s of lead dropped)", (pulledAtFlush - (size_t)(5 * kSGSingRate)) / (double)kSGSingRate);
    SGSingEngineDestroy(flushing);
    SGSingEngineDestroy(engine);
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    @autoreleasepool {
        if (argc < 4) {
            printf("usage: sing <separator.mlmodelc> <voice> <out dir> [all|cpu|gpu|ane]\n");
            return 2;
        }
        NSString *modelPath = @(argv[1]), *units = argc > 4 ? @(argv[4]) : @"all";
        sg_outDir = @(argv[3]);
        [NSFileManager.defaultManager createDirectoryAtPath:sg_outDir withIntermediateDirectories:YES attributes:nil error:nil];
        checkSTFT();

        MLModel *model = loadModel(modelPath, units);
        describePlan(modelPath, units);
        SGSingSeparator *separator = [[SGSingSeparator alloc] initWithModel:model];

        Audio voice = readAudio(@(argv[2]));
        size_t frames = (size_t)kSGSingRate * 30;
        frames = (frames - kSGSingWindowFrames) / kSGSingEngineHop * kSGSingEngineHop + kSGSingWindowFrames;
        Audio padded = makeAudio(frames), backing = chords(frames), mix = makeAudio(frames);
        for (size_t i = 0; i < frames; i++) {
            // The voice over and over, a second apart, from a second in.
            size_t from = i >= kSGSingRate ? (i - kSGSingRate) % (voice.frames + kSGSingRate) : voice.frames;
            padded.left[i] = padded.right[i] = from < voice.frames ? 0.5f * voice.left[from] : 0;
            mix.left[i] = padded.left[i] + backing.left[i];
            mix.right[i] = padded.right[i] + backing.right[i];
        }
        double slowest, average;
        Audio vocals = separateOffline(separator, mix, &slowest, &average);
        printf("  info  a two second window takes %.0f ms on average, %.0f ms at most (the first one warms the model up)\n", average * 1000, slowest * 1000);
        size_t to = frames - kSGSingWindowFrames / 2;
        double found = snr(padded, vocals, kSGSingRate, to), baseline = snr(padded, mix, kSGSingRate, to);
        CHECK(found > baseline + 10, "the vocals it finds score %.1f dB against the voice, the mix itself %.1f dB", found, baseline);
        Audio accompaniment = makeAudio(frames);
        for (size_t i = 0; i < frames; i++) {
            accompaniment.left[i] = mix.left[i] - vocals.left[i];
            accompaniment.right[i] = mix.right[i] - vocals.right[i];
        }
        printf("  info  the mix less them scores %.1f dB against the chords, the mix itself %.1f dB\n", snr(backing, accompaniment, kSGSingRate, to),
               snr(backing, mix, kSGSingRate, to));
        writeWAV(@"mix.wav", mix);
        writeWAV(@"vocals.wav", vocals);
        writeWAV(@"accompaniment.wav", accompaniment);

        checkEngine(separator, mix, padded, vocals);
        printf("%s\n", sg_failures ? "FAILED" : "all passed");
        return sg_failures ? 1 : 0;
    }
}
