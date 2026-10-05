#import <os/lock.h>
#import <pthread.h>
#import <stdatomic.h>
#import "SGSingEngine.h"
#import "SGSingSeparator.h"

enum {
    kRing = kSGSingRate * 10,        // what the rings hold: the longest lead and a window, with room to spare
    kLongestLead = kSGSingRate * 6,
    kShortestLead = kSGSingRate * 5 / 2,
};
// The lead asked for over a window: this many times the model's average time, and this much more.
static const double kLeadPerModelTime = 1.5, kLeadSpare = 0.25;
// The vocals come in and go out over this long, so the switch and the lead filling do not click.
static const float kFadeSeconds = 0.1f;
// How often the worker looks for a new window.
static const useconds_t kPoll = 10000;

struct SGSingEngine {
    float *left, *right, *vocalsLeft, *vocalsRight;   // rings, a frame at position p at p % kRing

    // Positions in frames of Spotify's sound since the engine was made: what was pulled, what was played,
    // and up to where the vocals are in.
    _Atomic uint64_t written, played, ready;
    _Atomic uint64_t base;        // where the worker starts over, at the latest flush
    atomic_uint generation;       // counts the flushes
    atomic_bool flushAsked, on, paused, hasSeparator;
    atomic_uint levelBits, targetLead;

    // The render thread's own.
    bool running;                 // the rings are in use: Sing is on, or the lead is not given back yet
    float amount, vocalsGain, otherGain;

    // The worker's.
    pthread_t worker;
    atomic_bool alive;
    os_unfair_lock lock;          // the separator and the error
    void *separator;              // retained
    NSString *error;
    float *window[2], *vocals[2];

    _Atomic uint64_t windows, failures, dryFrames, averageMicroseconds;
};

static float loadFloat(atomic_uint *slot) {
    uint32_t bits = atomic_load_explicit(slot, memory_order_relaxed);
    float value;
    memcpy(&value, &bits, sizeof value);
    return value;
}

static void storeFloat(atomic_uint *slot, float value) {
    uint32_t bits;
    memcpy(&bits, &value, sizeof bits);
    atomic_store(slot, bits);
}

#pragma mark - the render thread

// Starts the rings over where the mixer is now.
static void startOver(SGSingEngine *engine) {
    uint64_t written = atomic_load_explicit(&engine->written, memory_order_relaxed);
    atomic_store(&engine->played, written);
    atomic_store(&engine->base, written);
    atomic_fetch_add(&engine->generation, 1);
    engine->amount = 0;
}

// `count` frames from the mixer into the rings at `at`, in up to two runs where the ring wraps.
static OSStatus pullInto(SGSingEngine *engine, uint64_t at, uint64_t count, SGSingPull pull, void *context) {
    while (count) {
        uint64_t index = at % kRing, run = MIN(count, kRing - index);
        OSStatus status = pull(context, (UInt32)run, engine->left + index, engine->right + index);
        if (status != noErr) return status;
        at += run;
        count -= run;
    }
    return noErr;
}

// The gains for a level: the vocals up to 1, then the rest down to nothing at 2.
static void gainsFor(float level, float *vocals, float *other) {
    level = fmaxf(0, fminf(level, 2));
    *vocals = fminf(level, 1);
    *other = level <= 1 ? 1 : 2 - level;
}

OSStatus SGSingEngineRender(SGSingEngine *engine, UInt32 frames, float *left, float *right, SGSingPull pull, void *context) {
    // Larger than any slice an output asks for, and more than the rings leave room for: passed as it is.
    if (frames > kSGSingRate / 4) return pull(context, frames, left, right);
    bool on = atomic_load_explicit(&engine->on, memory_order_relaxed);
    if (!engine->running) {
        if (!on) return pull(context, frames, left, right);
        engine->running = true;
        startOver(engine);
        atomic_store(&engine->flushAsked, false);
    }
    if (atomic_exchange_explicit(&engine->flushAsked, false, memory_order_relaxed)) startOver(engine);

    uint64_t written = atomic_load_explicit(&engine->written, memory_order_relaxed);
    uint64_t played = atomic_load_explicit(&engine->played, memory_order_relaxed);
    uint64_t held = written - played;
    bool working = on && !atomic_load_explicit(&engine->paused, memory_order_relaxed)
                   && atomic_load_explicit(&engine->hasSeparator, memory_order_relaxed);
    int64_t want = (working ? (int64_t)atomic_load_explicit(&engine->targetLead, memory_order_relaxed) : 0) - (int64_t)held;
    // Up to twice what plays while the lead fills, half while it is given back.
    int64_t count = (int64_t)frames + MAX(-(int64_t)frames / 2, MIN(want, (int64_t)frames));
    count = MAX(count, (int64_t)frames - (int64_t)held);
    count = MIN(count, (int64_t)(kRing - kSGSingWindowFrames) - (int64_t)held);
    if (count > 0) {
        OSStatus status = pullInto(engine, written, (uint64_t)count, pull, context);
        if (status != noErr) {
            memset(left, 0, frames * sizeof(float));
            memset(right, 0, frames * sizeof(float));
            return status;
        }
        written += (uint64_t)count;
        atomic_store_explicit(&engine->written, written, memory_order_release);
    }

    uint64_t ready = atomic_load_explicit(&engine->ready, memory_order_acquire);
    float vocalsTo, otherTo;
    gainsFor(loadFloat(&engine->levelBits), &vocalsTo, &otherTo);
    float vocalsStep = (vocalsTo - engine->vocalsGain) / frames, otherStep = (otherTo - engine->otherGain) / frames;
    float fade = 1.0f / (kFadeSeconds * kSGSingRate), amountTo = on ? 1 : 0;
    uint64_t dry = 0;
    for (UInt32 i = 0; i < frames; i++) {
        uint64_t position = played + i, index = position % kRing;
        float x = engine->left[index], y = engine->right[index];
        engine->vocalsGain += vocalsStep;
        engine->otherGain += otherStep;
        if (position < ready) {
            engine->amount += fmaxf(-fade, fminf(amountTo - engine->amount, fade));
            float a = engine->amount, vocalsGain = engine->vocalsGain - 1, otherGain = engine->otherGain - 1;
            float v = engine->vocalsLeft[index], w = engine->vocalsRight[index];
            left[i] = x + a * (vocalsGain * v + otherGain * (x - v));
            right[i] = y + a * (vocalsGain * w + otherGain * (y - w));
        } else {
            engine->amount = 0;
            left[i] = x;
            right[i] = y;
            dry += on;
        }
    }
    engine->vocalsGain = vocalsTo;
    engine->otherGain = otherTo;
    played += frames;
    atomic_store_explicit(&engine->played, played, memory_order_release);
    if (dry) atomic_fetch_add_explicit(&engine->dryFrames, dry, memory_order_relaxed);
    // The lead given back and the vocals faded out: a straight pull from the next render on.
    if (!on && played == written) engine->running = false;
    return noErr;
}

#pragma mark - the worker

static void setError(SGSingEngine *engine, NSString *error) {
    os_unfair_lock_lock(&engine->lock);
    engine->error = error;
    os_unfair_lock_unlock(&engine->lock);
}

static SGSingSeparator *currentSeparator(SGSingEngine *engine) {
    os_unfair_lock_lock(&engine->lock);
    SGSingSeparator *separator = (__bridge SGSingSeparator *)engine->separator;
    os_unfair_lock_unlock(&engine->lock);
    return separator;
}

// The lead that keeps the vocals in ahead of what plays: a window, then the model's time and some spare.
static void updateTarget(SGSingEngine *engine, double modelSeconds) {
    double lead = kSGSingWindowFrames + (modelSeconds * kLeadPerModelTime + kLeadSpare) * kSGSingRate;
    atomic_store(&engine->targetLead, (unsigned)fmax(kShortestLead, fmin(lead, kLongestLead)));
}

static void *work(void *argument) {
    SGSingEngine *engine = argument;
    pthread_setname_np("spotifyglass.sing");
    unsigned generation = UINT_MAX;
    uint64_t start = 0, previousEnd = 0;
    while (atomic_load(&engine->alive)) {
        unsigned now = atomic_load(&engine->generation);
        if (now != generation) {
            generation = now;
            start = previousEnd = atomic_load(&engine->base);
            atomic_store_explicit(&engine->ready, start, memory_order_release);
        }
        SGSingSeparator *separator = currentSeparator(engine);
        uint64_t written = atomic_load_explicit(&engine->written, memory_order_acquire);
        uint64_t played = atomic_load_explicit(&engine->played, memory_order_relaxed);
        if (!separator || !atomic_load(&engine->on) || atomic_load(&engine->paused) || written < start + kSGSingWindowFrames) {
            usleep(kPoll);
            continue;
        }
        // Fallen behind what plays: the next window starts where the sound is, with nothing to crossfade with.
        if (start < played) start = previousEnd = played;
        if (written < start + kSGSingWindowFrames) continue;
        for (int c = 0; c < 2; c++) {
            const float *ring = c ? engine->right : engine->left;
            uint64_t index = start % kRing, run = MIN((uint64_t)kSGSingWindowFrames, kRing - index);
            memcpy(engine->window[c], ring + index, run * sizeof(float));
            memcpy(engine->window[c] + run, ring, (kSGSingWindowFrames - run) * sizeof(float));
        }
        CFAbsoluteTime began = CFAbsoluteTimeGetCurrent();
        NSError *error;
        BOOL separated;
        @autoreleasepool {
            separated = [separator separateLeft:engine->window[0] right:engine->window[1] vocalsLeft:engine->vocals[0]
                                    vocalsRight:engine->vocals[1] error:&error];
        }
        double took = CFAbsoluteTimeGetCurrent() - began;
        if (!separated) {
            atomic_fetch_add(&engine->failures, 1);
            setError(engine, error.localizedDescription ?: @"The model failed");
            usleep(1000000);
            continue;
        }
        setError(engine, nil);
        uint64_t windows = atomic_fetch_add(&engine->windows, 1);
        uint64_t average = atomic_load(&engine->averageMicroseconds);
        average = windows ? (uint64_t)(average * 0.8 + took * 1e6 * 0.2) : (uint64_t)(took * 1e6);
        atomic_store(&engine->averageMicroseconds, average);
        updateTarget(engine, average / 1e6);
        if (atomic_load(&engine->generation) != generation) continue;   // flushed meanwhile: the window is gone
        // The rings past `ready` are the worker's: the render thread reads only below it.
        for (uint64_t i = 0; i < kSGSingWindowFrames; i++) {
            uint64_t position = start + i, index = position % kRing;
            float a = position < previousEnd ? (float)(position - start) / (float)(previousEnd - start) : 1;
            engine->vocalsLeft[index] = engine->vocalsLeft[index] * (1 - a) + engine->vocals[0][i] * a;
            engine->vocalsRight[index] = engine->vocalsRight[index] * (1 - a) + engine->vocals[1][i] * a;
        }
        if (atomic_load(&engine->generation) == generation) atomic_store_explicit(&engine->ready, start + kSGSingEngineHop, memory_order_release);
        previousEnd = start + kSGSingWindowFrames;
        start += kSGSingEngineHop;
    }
    return NULL;
}

#pragma mark - any thread

SGSingEngine *SGSingEngineCreate(void) {
    SGSingEngine *engine = calloc(1, sizeof *engine);
    if (!engine) return NULL;
    engine->lock = OS_UNFAIR_LOCK_INIT;
    engine->left = calloc(kRing, sizeof(float));
    engine->right = calloc(kRing, sizeof(float));
    engine->vocalsLeft = calloc(kRing, sizeof(float));
    engine->vocalsRight = calloc(kRing, sizeof(float));
    for (int c = 0; c < 2; c++) {
        engine->window[c] = calloc(kSGSingWindowFrames, sizeof(float));
        engine->vocals[c] = calloc(kSGSingWindowFrames, sizeof(float));
    }
    engine->vocalsGain = engine->otherGain = 1;
    storeFloat(&engine->levelBits, 1);
    updateTarget(engine, 1);
    atomic_store(&engine->alive, true);
    if (!engine->left || !engine->right || !engine->vocalsLeft || !engine->vocalsRight || !engine->window[0] || !engine->window[1]
        || !engine->vocals[0] || !engine->vocals[1] || pthread_create(&engine->worker, NULL, work, engine) != 0) {
        atomic_store(&engine->alive, false);
        engine->worker = NULL;
        SGSingEngineDestroy(engine);
        return NULL;
    }
    return engine;
}

void SGSingEngineDestroy(SGSingEngine *engine) {
    if (!engine) return;
    atomic_store(&engine->alive, false);
    if (engine->worker) pthread_join(engine->worker, NULL);
    if (engine->separator) CFRelease(engine->separator);
    engine->error = nil;
    for (int c = 0; c < 2; c++) {
        free(engine->window[c]);
        free(engine->vocals[c]);
    }
    free(engine->left);
    free(engine->right);
    free(engine->vocalsLeft);
    free(engine->vocalsRight);
    free(engine);
}

void SGSingEngineSetSeparator(SGSingEngine *engine, SGSingSeparator *separator) {
    void *retained = separator ? (void *)CFBridgingRetain(separator) : NULL;
    os_unfair_lock_lock(&engine->lock);
    void *old = engine->separator;
    engine->separator = retained;
    os_unfair_lock_unlock(&engine->lock);
    atomic_store(&engine->hasSeparator, retained != NULL);
    // Released outside the lock; the worker holds its own reference while it runs one.
    if (old) CFRelease(old);
}

void SGSingEngineSetOn(SGSingEngine *engine, bool on) {
    atomic_store(&engine->on, on);
}

bool SGSingEngineOn(SGSingEngine *engine) {
    return atomic_load(&engine->on);
}

void SGSingEngineSetLevel(SGSingEngine *engine, float level) {
    storeFloat(&engine->levelBits, level);
}

void SGSingEngineSetPaused(SGSingEngine *engine, bool paused) {
    atomic_store(&engine->paused, paused);
}

void SGSingEngineFlush(SGSingEngine *engine) {
    atomic_store(&engine->flushAsked, true);
}

double SGSingEngineLead(SGSingEngine *engine) {
    if (!engine) return 0;
    uint64_t played = atomic_load_explicit(&engine->played, memory_order_relaxed);
    uint64_t written = atomic_load_explicit(&engine->written, memory_order_relaxed);
    return written > played ? (double)(written - played) / kSGSingRate : 0;
}

SGSingEngineStats SGSingEngineReadStats(SGSingEngine *engine) {
    uint64_t played = atomic_load(&engine->played), ready = atomic_load(&engine->ready);
    return (SGSingEngineStats){
        .lead = SGSingEngineLead(engine),
        .targetLead = atomic_load(&engine->targetLead) / (double)kSGSingRate,
        .ready = ((double)ready - (double)played) / kSGSingRate,
        .averageMS = atomic_load(&engine->averageMicroseconds) / 1000.0,
        .windows = atomic_load(&engine->windows),
        .failures = atomic_load(&engine->failures),
        .dryFrames = atomic_load(&engine->dryFrames),
    };
}

NSString *SGSingEngineError(SGSingEngine *engine) {
    os_unfair_lock_lock(&engine->lock);
    NSString *error = engine->error;
    os_unfair_lock_unlock(&engine->lock);
    return error;
}
