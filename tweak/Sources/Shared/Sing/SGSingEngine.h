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
// What plays is the lead behind what Spotify's decoder has handed over, which is what Spotify's clock
// counts: Sing.x takes the lead off the player's position, and asks for a flush when Spotify seeks or
// skips, which drops the sound held from before it.
//
// Threading: SGSingEngineRender on the render thread only, allocation and lock free; the worker is the
// engine's own; everything else from any thread.
#import <Foundation/Foundation.h>

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
    unsigned long long windows, failures, dryFrames;   // dry: frames played unseparated while on
} SGSingEngineStats;
SGSingEngineStats SGSingEngineReadStats(SGSingEngine *engine);
// The model's last error, nil when its last window went through.
NSString *SGSingEngineError(SGSingEngine *engine);
