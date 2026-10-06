// Moving artwork for a track: its Canvas, or Apple Music's animated album cover where the album has one,
// and for the lock screen, failing both, the cover over a moving blur of itself (SGFluidClip.h).
// SGMotionCatalog.m looks covers and logos up in Apple Music's catalog. SGMotionStore.m keeps every video
// as a local file, the form the system's lock screen takes.
#import <UIKit/UIKit.h>

// What the lock screen fills the screen with, stored as the index of SGLockArtwork. It took over from the
// Moving artwork switch, whose key is moved onto it once: on is Moving artwork, off is Off.
#define SGKeyLockScreenArtwork @"spotifyglass.lockscreen.artwork"
#define SGKeyLockScreenMotion @"spotifyglass.lockscreen.motion"
typedef NS_ENUM(NSInteger, SGLockArtwork) {
    SGLockArtworkOff = 0,
    SGLockArtworkMotion,   // the Canvas, else Apple Music's animated cover (LockScreenMotion.x)
    SGLockArtworkLyrics,   // a clip per line of lyrics (Shared/LockScreenLyrics/LyricsArtwork.x)
    SGLockArtworkEverySong,   // Moving artwork, else the cover over a moving blur of it (LockScreenMotion.x)
};
// Off below iOS 26, which has no animated artwork on the lock screen.
SGLockArtwork SGLockScreenArtwork(void);
// How the lyrics are drawn, stored as the index of SGLyricsClipStyle (Still unless changed).
#define SGKeyLockScreenLyricsStyle @"spotifyglass.lockscreen.lyricsStyle"
// Off until switched on: download in Low Data Mode too.
#define SGKeyMotionLowData @"spotifyglass.motion.lowdata"

typedef NS_ENUM(NSInteger, SGMotionShape) {
    SGMotionSquare,   // 1:1
    SGMotionTall,     // 3:4
};

// Apple Music's animated cover for an album, as a local file, or nil. `done` runs on the main queue.
// `pixels` is the width it is shown at; the closest stream at or above it is downloaded.
void SGMotionAlbumCover(NSString *artist, NSString *album, SGMotionShape shape, CGFloat pixels,
                        void (^done)(NSURL *file));

// The artist's logo from Apple Music, a transparent PNG `pixels` wide, or nil. Main queue.
void SGMotionArtistLogo(NSString *artist, CGFloat pixels, void (^done)(UIImage *logo));

// The width a full-screen clip is downloaded at: three quarters of the screen's pixels. A tall cover at the
// screen's full width ran to 29 MB a song; at this width it was 7 MB and looks the same in motion.
CGFloat SGMotionPixels(void);

// Apple Music's catalog songs with this ISRC, each with its isrc, durationInMillis and hasHaptics, or nil
// when the catalog could not be asked. Kept for the launch. Main queue.
void SGMotionSongsWithISRC(NSString *isrc, void (^done)(NSArray *songs));

// Any remote video (a Canvas) as a local file, or nil. Main queue.
void SGMotionFile(NSURL *remote, void (^done)(NSURL *file));
// Where a video the mod makes itself is kept under `key`, among the downloads, which are kept to the
// newest few. Whether it is there yet is the caller's to check. Any thread.
NSURL *SGMotionMadeFile(NSString *key);

// The first frame of a local video. Main queue.
void SGMotionPoster(NSURL *file, void (^done)(UIImage *poster));

// Settings: what the lock screen shows, the lyrics' style and Low Data Mode.
NSArray *SGLockScreenMotionRows(void);

// Pure steps, for the harness.
NSString *SGMotionNameKey(NSString *name);
NSString *SGMotionStreamIn(NSString *master, CGFloat pixels);
NSString *SGMotionWholeFileIn(NSString *media);
