// Sing's engine: the vocals of what Spotify plays separated ahead of it, and turned down as it plays.
//
// The model takes two seconds at a time and is far too slow for the render thread, so the engine stands
// between Spotify's mixer and its output and pulls the mixer ahead of what plays: up to twice what a
// render asks for, until the sound it holds (the lead) is a window plus the model's time. A worker thread
// takes the held sound two seconds at a time, every 1.5 s, runs the separator and writes the vocals into a
// second ring beside it, the half second the windows share crossfaded. Each render plays the held sound
// from the oldest frame on, the vocals turned down by the level wherever they are in, and dry wherever
// they are not yet (as the lead fills, or when the model falls behind). Switched off, it pulls half of
// what plays until the lead is given back, and is a straight pull again.
//
// Spatial voice: the vocals' middle (left plus right, halved) can be put at an angle off straight ahead,
// where Sing.x holds it as the head turns. The ear facing it hears it louder and the other quieter at the same
// power (an equal-power pan, narrowed so that the far ear never loses it), and the far ear hears it up to
// 0.65 ms later (the time sound takes around a head) and duller, through a one-pole low-pass for the head's
// shadow. The vocals' sides (left less right, halved) stay where they are, so straight ahead plays the vocals
// exactly as separated.
//
// What plays is the lead behind what Spotify's decoder has handed over, which is what Spotify's clock
// counts: Sing.x takes the lead off the player's position, and asks for a flush when Spotify seeks or
// skips, which drops the sound held from before it.
//
// Threading: SGSingEngineRender on the render thread only, allocation and lock free; the worker is the
// engine's own; everything else from any thread.
#import <Foundation/Foundation.h>
#import <math.h>

@class SGSingSeparator;

enum {
    kSGSingEngineHop = 66150,   // 1.5 s between windows, so neighbours share half a second
};

typedef struct SGSingEngine SGSingEngine;

// Fills `frames` frames of each channel with the next of Spotify's sound.
typedef OSStatus (*SGSingPull)(void *context, UInt32 frames, float *left, float *right);

SGSingEngine *SGSingEngineCreate(void);
// Stops the worker and frees the engine; nothing may be rendering through it.
void SGSingEngineDestroy(SGSingEngine *engine);
// The separator the worker runs, nil for none (what plays is then dry).
void SGSingEngineSetSeparator(SGSingEngine *engine, SGSingSeparator *separator);
void SGSingEngineSetOn(SGSingEngine *engine, bool on);
bool SGSingEngineOn(SGSingEngine *engine);
// The vocals' level from 0 (gone) through 1 (as the song has them) to 2 (the vocals alone, the rest gone).
void SGSingEngineSetLevel(SGSingEngine *engine, float level);
// Where the separated voice sounds, in radians to the listener's right of straight ahead (left is negative,
// behind sounds as the front does): 0, where it starts, leaves the vocals exactly as the song has them. The
// render glides to a new angle over a few tens of milliseconds, so it can be set as often as the head moves.
void SGSingEngineSetVoiceAngle(SGSingEngine *engine, float radians);

// Where spatial voice holds the voice, for Sing.x and the Spatial voice page's preview alike: off a front that
// follows where the head points over 20 s, so the voice drifts back ahead of a head that stays turned and the
// attitude's own drift never carries it off. A gap in the motion over 1 s (headphones out and in again), or a
// front cleared to zero, starts it over where the head points.
typedef struct {
    bool hasFront;
    double front, last;
} SGSpatialFront;

// The voice's angle off the head in radians to its right, from a head motion's yaw and timestamp (seconds).
static inline double SGSpatialVoiceAngle(SGSpatialFront *f, double yaw, double time) {
    // CoreMotion's yaw turns counterclockwise seen from above, so it grows as the head turns left, and the voice
    // held ahead is then off to the head's right. Not yet heard on AirPods; flip it here.
    const double yawToRight = 1;
    const double frontSeconds = 20, motionGap = 1;
    double since = time - f->last;
    if (!f->hasFront || since < 0 || since > motionGap) f->front = yaw;
    else f->front = remainder(f->front + remainder(yaw - f->front, 2 * M_PI) * (1 - exp(-since / frontSeconds)), 2 * M_PI);
    f->hasFront = true;
    f->last = time;
    return yawToRight * remainder(yaw - f->front, 2 * M_PI);
}
// Holds the worker (a hot phone): what plays is dry, and the lead is given back.
void SGSingEngineSetPaused(SGSingEngine *engine, bool paused);
// Drops the sound held ahead, at the next render.
void SGSingEngineFlush(SGSingEngine *engine);
// Seconds of Spotify's sound held ahead of what plays.
double SGSingEngineLead(SGSingEngine *engine);

OSStatus SGSingEngineRender(SGSingEngine *engine, UInt32 frames, float *left, float *right, SGSingPull pull, void *context);

typedef struct {
    double lead, targetLead;   // seconds
    double ready;              // seconds of the held sound separated, ahead of what plays (negative when behind)
    double averageMS;          // a window's separation, a running average
    double voiceAngle;         // radians, as last set
    unsigned long long windows, failures, dryFrames;   // dry: frames played unseparated while on
} SGSingEngineStats;
SGSingEngineStats SGSingEngineReadStats(SGSingEngine *engine);
// The model's last error, nil when its last window went through.
NSString *SGSingEngineError(SGSingEngine *engine);
