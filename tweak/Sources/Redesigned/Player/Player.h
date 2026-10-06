// The player redesign (screen key "player"): Spotify's full screen player kept, with its controller,
// units, controls and card list, and restyled from the Kit. Every control stays Spotify's own, so its
// action, state and accessibility do too; the redesign adds the artwork field behind it, glass behind
// the header buttons, bare glyphs for previous, play and next, a lyrics glyph in the footer, and one
// screen with nothing under it: every card is collapsed and the player does not scroll. The lyrics
// come to the player itself, the way the Music app shows them, when the lyrics glyph is tapped.
//
//     PlayerField.x      the switch's flags and rows, the field in the background plane, the cover it reads
//     PlayerArtwork.x    the cover's corners, shadow and paused shrink, the lyric preview under it gone and
//                        its room the cover's
//     PlayerHeader.x     glass behind the close and more buttons
//     PlayerControls.x   previous, play and next as bare glyphs, monospaced times
//     PlayerFooter.x     share gone, lyrics, Connect and queue as one row of three glyphs
//     PlayerCards.x      every card under the player collapsed, so the list closes up
//     PlayerScroll.x     the list held at its top, so the player is one screen and cannot be scrolled up,
//                        and its pull held off while the progress bar is scrubbed
//     PlayerLyrics.x     the lyrics in the player: the cover as a thumbnail, the title up beside it
//     PlayerGestures.x   the gestures' hookup
//     PlayerMorph.x      the open and close grown out of the now playing bar's card, the cover flown
//     PlayerMotion.x     Animated artwork: the Canvas or Apple Music's animated cover behind the player
//     PlayerMenu.m       the more button's system menu: Share, Add to playlist and Add to queue on top, then
//                        speed, pitch and reverb and Show Animated or Fluid artwork, and Spotify's other rows
//                        under More (Redesigned/ContextMenu)
//     PlayerSettings.m   the Player page in Mod Settings, led by a showcase of the player
//     PlayerFree.x       a Spotify Free account given the player mode these units belong to
//
// Speed and pitch, once the redesign's own, are Shared/Player/SpeedPitch.h's; PlayerHeader.x still hands
// the more button over, so a menu opened from it is taken for the player's, and hands it to PlayerMenu.m,
// which opens it as the system menu.
//
// Every hook installs only while Redesigned UI is on (SGRedesignedUI); the native look's do not then.
// Threading: main thread only.
#import <UIKit/UIKit.h>

@class SGRArtworkField;

// What is behind the player, chosen on the Player page (PlayerSettings.m).
// SGRKeyPlayerMotion is the switch the choice replaced: until a choice is stored, it picks Still or Colours.
#define SGRKeyPlayerBackground @"spotifyglass.redesign.player.background"
#define SGRKeyPlayerMotion @"spotifyglass.redesign.player.movingBackground"
typedef NS_ENUM(NSInteger, SGRPlayerBackgroundKind) {
    SGRPlayerBackgroundStill,      // the artwork blurred and held still
    SGRPlayerBackgroundColours,    // the artwork's colours drifting (SGRFlow.h)
    SGRPlayerBackgroundFluid,      // the artwork itself blurred and turning (SGRFluid.h)
    SGRPlayerBackgroundAnimated,   // the track's Canvas or Apple Music's animated cover, over Fluid (PlayerMotion.x);
                                   // the player's ⋯ menu switches between this and Fluid
};
SGRPlayerBackgroundKind SGRPlayerBackground(void);
// The names of the choices, in order.
NSArray<NSString *> *SGRPlayerBackgroundNames(void);

// The field behind the player, nil until the player has laid out once (PlayerField.x).
SGRArtworkField *SGRPlayerField(void);

#pragma mark - the cover (PlayerArtwork.x)

// The sideways list of covers behind the player, nil until one has laid out.
UIView *SGRPlayerCoverList(void);
// The cover on screen as it is drawn, its paused shrink included, in `host`'s coordinates; CGRectNull
// when no cover has laid out.
CGRect SGRPlayerCoverFrameIn(UIView *host);
// The scale the cover is drawn at: 1 while playing, its shrink while paused, so a stand-in can draw its
// corners the size the cover's are.
CGFloat SGRPlayerCoverScale(void);
// The band that cover sits in -- the room the player gives its artwork, between the header row and the
// title -- in `host`'s coordinates; CGRectNull when no cover has laid out.
CGRect SGRPlayerArtworkAreaIn(UIView *host);
// Hides the cover on screen and its shadow, or shows them again, for a stand-in to fly in its place
// (PlayerMorph.x).
void SGRPlayerSetCoverHidden(BOOL hidden);

#pragma mark - the lyrics in the player (PlayerLyrics.x)

// Whether the playing track has lyrics the player can show.
BOOL SGRPlayerLyricsAvailable(void);
// Whether the player is showing them.
BOOL SGRPlayerLyricsOpen(void);
// Shows them, or puts the cover back; does nothing when there are none to show.
void SGRPlayerToggleLyrics(void);
// Called by PlayerLyrics.x whenever either of those two changed, so the footer's lyrics glyph follows
// (PlayerFooter.x). It returns at once when nothing changed.
void SGRPlayerLyricsChanged(void);
// The controls under the lines fade a few seconds after the last touch while the lyrics play, and the
// lines grow down into their room (PlayerLyrics.x). On until switched off; a scroll through the lines
// hides them either way.
#define SGRKeyLyricsAutoHide @"spotifyglass.redesign.lyrics.autoHide"

// The lyrics turn sideways with the phone onto a landscape screen of their own (PlayerLandscape.x). On
// until switched off. Shown or put away by hand for the harness.
#define SGRKeyLyricsLandscape @"spotifyglass.redesign.lyrics.landscape"
void SGRPlayerShowLandscape(BOOL show);

// The animated artwork follows the lyrics: blurred behind them (PlayerMotion.x).
void SGRPlayerMotionLyricsChanged(void);
// The field was laid out (PlayerField.x): the clip goes onto it, and the cover is hidden or shown again.
void SGRPlayerMotionFieldLaidOut(void);
// A clip is playing in place of the cover, which is then hidden: the lyrics' thumbnail and the open's
// flown cover fade where they are rather than flying to or from it.
BOOL SGRPlayerMotionShowing(void);
// A view of its own playing that clip, drawn as the player draws it (its foot, the blur under the controls),
// for the Player page's showcase; nil while no clip plays. It plays only in a window, like the player's.
UIView *SGRPlayerMotionPreview(void);

#pragma mark - Mod Settings (PlayerSettings.m)

// The redesign's Player page: a card of the player over the background chosen and the control that picks
// it, the background's rows and the Mini player section under it, then `more`, the sections either look
// shares (App/Pages.m).
UIViewController *SGRPlayerSettingsPage(NSArray *more);

// Alpha 0, no touches, hidden from accessibility, set again on every call: for Spotify's Swift views,
// which SGRSuppress cannot keep (PlayerControls.x).
void SGRPlayerVanish(UIView *view);

// The tap to seek around the progress bar (PlayerControls.x), apart for the harness: whether a tap at `point`
// in the duration unit's view seeks, and the share of the song a point on the slider stands for, measured
// over the thumb's travel (NAN while the slider has no width).
BOOL SGRSeekTapLands(UIView *unit, UISlider *slider, CGPoint point);
CGFloat SGRSeekShareAt(UISlider *slider, CGPoint point);

// The more button's menu opens as the system menu with the player's own items (PlayerMenu.m). Called from
// PlayerHeader.x with Spotify's more button on every pass; watching it again changes nothing.
void SGRPlayerMenuWatch(UIView *button);
