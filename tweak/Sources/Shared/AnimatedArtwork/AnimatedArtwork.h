// Moving artwork for a track: its Canvas, or Apple Music's animated album cover where the album has one.
// SGMotionCatalog.m looks covers and logos up in Apple Music's catalog. SGMotionStore.m keeps every video
// as a local file, the form the system's lock screen takes.
#import <UIKit/UIKit.h>

// Off until switched on.
#define SGKeyLockScreenMotion @"spotifyglass.lockscreen.motion"
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

// Any remote video (a Canvas) as a local file, or nil. Main queue.
void SGMotionFile(NSURL *remote, void (^done)(NSURL *file));

// The first frame of a local video. Main queue.
void SGMotionPoster(NSURL *file, void (^done)(UIImage *poster));

// Settings: the lock screen switch and Low Data Mode.
NSArray *SGLockScreenMotionRows(void);

// Pure steps, for the harness.
NSString *SGMotionNameKey(NSString *name);
NSString *SGMotionStreamIn(NSString *master, CGFloat pixels);
NSString *SGMotionWholeFileIn(NSString *media);
