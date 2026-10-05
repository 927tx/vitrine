// Speed and pitch: two sliders in the more button's menu, done to Spotify's sound, under either look.
// Nothing here draws on a Spotify screen of its own: the block goes into Spotify's own context menu
// sheet, and the rest is audio.
//
//     SpeedPitchMenu.x   the expandable row and its two sliders, put into Spotify's context menu, and under
//                        the redesign the Animated artwork switch under them
//     SpeedPitch.x       speed and pitch done to Spotify's audio, between its mixer and its speaker unit
//     SGTimePitch.m      Apple's time and pitch unit, pulling the mixer or working in place
//
// Speed and pitch last until Spotify quits; neither is stored.
// Threading: main thread only, except what SGTimePitch.h says runs on the render thread.
#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>

// Marks a menu opened soon after a tap on `button`, the player's more button, as the player's, so it gets
// Speed and pitch (watching it twice does nothing). The redesign's PlayerHeader.x hands its button over;
// a menu presented from a now playing controller is taken for the player's without it, which is how the
// native look's player gets the block.
void SGPlayerMenuWatchMoreButton(UIView *button);
// Whether a context menu sheet is the player's, by the same test; decided once per menu.
BOOL SGPlayerMenuIsPlayers(UIViewController *menu);
// The speed Spotify's sound plays at, 1 when normal.
double SGPlayerSpeed(void);
// Whether speed can apply: Spotify's output was taken over when it wired it.
BOOL SGPlayerSpeedAllowed(void);
void SGSetPlayerSpeed(double speed);
// Semitones Spotify's output is moved by, 0 when it is not.
float SGPlayerPitch(void);
void SGSetPlayerPitch(float semitones);
// Speed and pitch move together, like a record, by resampling rather than the time stretch. On until
// switched off, from the switch under the two sliders.
#define SGKeyPitchFollowsSpeed @"spotifyglass.speed.pitchFollows"
BOOL SGPlayerPitchFollowsSpeed(void);
void SGSetPlayerPitchFollowsSpeed(BOOL follows);
// Whether the output could be reached to change its pitch.
BOOL SGPlayerPitchAvailable(void);

// The redesign's Animated artwork, switched in the same block: whether the player offers the switch (the
// redesign is running and its background is Fluid or Animated, the two that share a field), whether it is
// on, and switching it, which applies at once and is stored as the Background choice. Defined by
// Redesigned/Player/PlayerMotion.x; NO from the first under the native look.
BOOL SGPlayerMenuOffersAnimatedArtwork(void);
BOOL SGPlayerMenuAnimatedArtwork(void);
void SGPlayerMenuSetAnimatedArtwork(BOOL on);
// A stage between Spotify's mixer and the rest of the chain (Sing's look-ahead, Shared/Sing): it fills the
// chain's buffers, pulling the mixer through `pull` as much as it likes. NULL passes the mixer straight on.
// Called on the render thread, and only while Spotify's connection is taken over (SGPlayerSpeedAllowed).
typedef OSStatus (*SGPlayerPull)(void *context, UInt32 frames, AudioBufferList *data);
typedef OSStatus (*SGPlayerStage)(UInt32 frames, AudioBufferList *data, SGPlayerPull pull, void *context);
void SGPlayerSetStage(SGPlayerStage stage);
