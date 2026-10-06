// The lock screen's artwork moves: the track's Canvas, else Apple Music's animated album cover, and with
// Every song chosen, failing both, the cover over a moving blur of itself (SGFluidClip.h). iOS 26 takes a
// local video through MPMediaItemAnimatedArtwork under one of two now playing keys, 1:1 or 3:4, picked
// here by the video's own shape. It rides on Spotify's now playing info as an extra
// (Shared/Player/NowPlayingExtras.h).
//
// The cover's clip is made only when the lock screen asks for its video, from the cover Spotify gave the
// system, and kept by the picture the track names, so an album's songs share one.
#import <MediaPlayer/MediaPlayer.h>
#import "Core/SGCore.h"
#import "AnimatedArtwork.h"
#import "SGFluidClip.h"
#import "Shared/LockScreenLyrics/SGLyricsClip.h"
#import "Shared/Player/NowPlayingExtras.h"
#import "Shared/Player/PlayerState.h"

static NSString *sg_track;   // the URI the artwork is for
static NSString *sg_title;
static dispatch_queue_t sg_queue;   // makes the cover's clips, one at a time

API_AVAILABLE(ios(26.0))
static void show(NSString *uri, NSURL *file) {
    if (!file || ![uri isEqualToString:sg_track]) return;
    SGMotionPoster(file, ^(UIImage *poster) {
        if (!poster || ![uri isEqualToString:sg_track]) return;
        CGSize size = poster.size;
        BOOL square = fabs(size.width - size.height) < size.height * 0.05;
        NSString *key = square ? MPNowPlayingInfoProperty1x1AnimatedArtwork : MPNowPlayingInfoProperty3x4AnimatedArtwork;
        MPMediaItemAnimatedArtwork *artwork = [[MPMediaItemAnimatedArtwork alloc] initWithArtworkID:file.lastPathComponent
            previewImageRequestHandler:^(CGSize wanted, void (^completion)(UIImage *)) { completion(poster); }
            videoAssetFileURLRequestHandler:^(CGSize wanted, void (^completion)(NSURL *)) { completion(file); }];
        SGNowPlayingSetExtras(@"motion", @{key: artwork}, sg_title);
        SGLog(@"lock motion: %@ as %@", file.lastPathComponent, square ? @"1:1" : @"3:4");
    });
}

// The cover Spotify handed the system for `title`, read on the main thread as LyricsArtwork.x reads it,
// then `then` on sg_queue with it, or with NULL when the info is another song's or has none.
static void withCover(NSString *title, void (^then)(CGImageRef cover)) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary *info = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo;
        MPMediaItemArtwork *artwork = info[MPMediaItemPropertyArtwork];
        UIImage *cover = [info[MPMediaItemPropertyTitle] isEqual:title] && [artwork isKindOfClass:MPMediaItemArtwork.class]
            ? [artwork imageWithSize:CGSizeMake(600, 600)] : nil;
        dispatch_async(sg_queue, ^{ then(cover.CGImage); });
    });
}

// The picture the track names, so the songs of an album share a clip; the track itself when it names none.
static NSString *pictureOf(SPTPlayerTrack *track, NSDictionary *metadata) {
    for (NSString *field in @[@"image_xlarge_url", @"image_large_url", @"image_url"]) {
        id value = metadata[field];
        if ([value isKindOfClass:NSString.class] && [value length]) return value;
    }
    return SGURIString(track.URI);
}

API_AVAILABLE(ios(26.0))
static void showCover(NSString *uri, NSString *picture) {
    if (![uri isEqualToString:sg_track]) return;
    NSURL *file = SGMotionMadeFile([@"fluid\n" stringByAppendingString:picture]);
    NSString *title = sg_title;
    CGSize size = SGLyricsClipSize(SGMotionPixels());
    MPMediaItemAnimatedArtwork *artwork = [[MPMediaItemAnimatedArtwork alloc] initWithArtworkID:file.lastPathComponent
        previewImageRequestHandler:^(CGSize wanted, void (^completion)(UIImage *)) {
            withCover(title, ^(CGImageRef cover) {
                CGImageRef frame = SGFluidClipFrame(cover, size);
                completion(frame ? [UIImage imageWithCGImage:frame] : nil);
                CGImageRelease(frame);
            });
        }
        videoAssetFileURLRequestHandler:^(CGSize wanted, void (^completion)(NSURL *)) {
            withCover(title, ^(CGImageRef cover) {
                CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
                BOOL ok = [NSFileManager.defaultManager fileExistsAtPath:file.path] || SGFluidClipWrite(file, cover, size);
                SGLog(@"lock motion: the cover's clip %@ %@ in %.0f ms", file.lastPathComponent, ok ? @"ready" : @"not written",
                      (CFAbsoluteTimeGetCurrent() - start) * 1000);
                completion(ok ? file : nil);
            });
        }];
    SGNowPlayingSetExtras(@"motion", @{MPNowPlayingInfoProperty3x4AnimatedArtwork: artwork}, title);
    SGLog(@"lock motion: no moving artwork, the cover's clip offered as %@", file.lastPathComponent);
}

@interface SGLockScreenMotion : NSObject <SGPlayerStateObserver>
@end

@implementation SGLockScreenMotion
- (void)playerStateDidChange:(SPTPlayerState *)state {
    if (@available(iOS 26.0, *)) {
        NSString *uri = SGURIString(state.track.URI);
        if (!uri || [uri isEqualToString:sg_track]) return;
        sg_track = uri;
        sg_title = state.track.trackTitle;
        SGNowPlayingSetExtras(@"motion", nil, nil);
        NSDictionary *metadata = [state.track.metadata isKindOfClass:NSDictionary.class] ? state.track.metadata : nil;
        NSString *artist = state.track.artistName, *album = metadata[@"album_title"];
        id type = metadata[@"canvas.type"], address = metadata[@"canvas.url"];
        BOOL video = [type isKindOfClass:NSString.class] && [type rangeOfString:@"video" options:NSCaseInsensitiveSearch].location != NSNotFound;
        NSURL *canvas = video && [address isKindOfClass:NSString.class] ? [NSURL URLWithString:address] : nil;
        CGFloat pixels = SGMotionPixels();
        BOOL everySong = SGLockScreenArtwork() == SGLockArtworkEverySong;
        NSString *picture = pictureOf(state.track, metadata);
        SGMotionClipFor(canvas, artist, album, SGMotionTall, pixels, ^(NSURL *file) {
            if (file) show(uri, file);
            else if (everySong) showCover(uri, picture);
        });
    }
}
@end

%ctor {
    SGLockArtwork choice = SGLockScreenArtwork();
    if (choice != SGLockArtworkMotion && choice != SGLockArtworkEverySong) return;
    if (@available(iOS 26.0, *)) {
        sg_queue = dispatch_queue_create("spotifyglass.lockscreen.motion", DISPATCH_QUEUE_SERIAL);
        static SGLockScreenMotion *observer;
        observer = [SGLockScreenMotion new];
        SGAddPlayerStateObserver(observer);
        SGLog(@"lock motion: on%@, the lock screen takes %@", choice == SGLockArtworkEverySong ? @" for every song" : @"",
              MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys);
    }
}
