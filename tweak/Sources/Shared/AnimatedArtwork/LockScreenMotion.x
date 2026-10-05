// The lock screen's artwork moves: the track's Canvas, else Apple Music's animated album cover. iOS 26
// takes a local video through MPMediaItemAnimatedArtwork under one of two now playing keys, 1:1 or 3:4,
// picked here by the video's own shape.
//
// Spotify's now playing info passes through with the artwork added. Lock screen lyrics hooks the same
// setter and keeps Spotify's own dictionary behind the getter, so this hook stores nothing of it: once
// a video is ready, the info the getter gives back is sent again with its clock moved on.
#import <MediaPlayer/MediaPlayer.h>
#import "Core/SGCore.h"
#import "AnimatedArtwork.h"
#import "Shared/Player/PlayerState.h"

// Read on whatever thread Spotify sets the info from, written on the main one.
static NSObject *sg_lock;
static NSString *sg_title;
static NSDictionary *sg_motion;
static double sg_elapsed, sg_rate;
static CFAbsoluteTime sg_clockAt;

static NSString *sg_track;   // main thread: the URI the artwork is for

API_AVAILABLE(ios(26.0))
static void resend(void) {
    MPNowPlayingInfoCenter *center = MPNowPlayingInfoCenter.defaultCenter;
    NSMutableDictionary *info = [center.nowPlayingInfo mutableCopy];
    if (!info) return;
    @synchronized (sg_lock) {
        if (sg_clockAt > 0) info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(sg_elapsed + sg_rate * (CFAbsoluteTimeGetCurrent() - sg_clockAt));
    }
    center.nowPlayingInfo = info;
}

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
        @synchronized (sg_lock) {
            sg_motion = @{key: artwork};
        }
        SGLog(@"lock motion: %@ as %@", file.lastPathComponent, square ? @"1:1" : @"3:4");
        resend();
    });
}

@interface SGLockScreenMotion : NSObject <SGPlayerStateObserver>
@end

@implementation SGLockScreenMotion
- (void)playerStateDidChange:(SPTPlayerState *)state {
    if (@available(iOS 26.0, *)) {
        NSString *uri = SGURIString(state.track.URI);
        if (!uri || [uri isEqualToString:sg_track]) return;
        sg_track = uri;
        @synchronized (sg_lock) {
            sg_title = state.track.trackTitle;
            sg_motion = nil;
        }
        NSDictionary *metadata = [state.track.metadata isKindOfClass:NSDictionary.class] ? state.track.metadata : nil;
        NSString *artist = state.track.artistName, *album = metadata[@"album_title"];
        id type = metadata[@"canvas.type"], address = metadata[@"canvas.url"];
        BOOL video = [type isKindOfClass:NSString.class] && [type rangeOfString:@"video" options:NSCaseInsensitiveSearch].location != NSNotFound;
        NSURL *canvas = video && [address isKindOfClass:NSString.class] ? [NSURL URLWithString:address] : nil;
        CGFloat pixels = UIScreen.mainScreen.nativeBounds.size.width;
        void (^apple)(void) = ^{
            SGMotionAlbumCover(artist, album, SGMotionTall, pixels, ^(NSURL *file) { show(uri, file); });
        };
        if (!canvas) {
            apple();
            return;
        }
        SGMotionFile(canvas, ^(NSURL *file) {
            if (file) show(uri, file);
            else apple();
        });
    }
}
@end

%hook MPNowPlayingInfoCenter
- (void)setNowPlayingInfo:(NSDictionary *)info {
    NSDictionary *motion = nil;
    @synchronized (sg_lock) {
        if (info[MPNowPlayingInfoPropertyElapsedPlaybackTime]) {
            sg_elapsed = [info[MPNowPlayingInfoPropertyElapsedPlaybackTime] doubleValue];
            sg_rate = [info[MPNowPlayingInfoPropertyPlaybackRate] doubleValue];
            sg_clockAt = CFAbsoluteTimeGetCurrent();
        }
        if (sg_motion && [info[MPMediaItemPropertyTitle] isEqual:sg_title]) motion = sg_motion;
    }
    if (!motion) {
        %orig;
        return;
    }
    NSMutableDictionary *withMotion = [info mutableCopy];
    [withMotion addEntriesFromDictionary:motion];
    %orig(withMotion);
}
%end

%ctor {
    if (!SGFlag(SGKeyLockScreenMotion, NO)) return;
    if (@available(iOS 26.0, *)) {
        sg_lock = [NSObject new];
        %init;
        static SGLockScreenMotion *observer;
        observer = [SGLockScreenMotion new];
        SGAddPlayerStateObserver(observer);
        SGLog(@"lock motion: on, the lock screen takes %@", MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys);
    }
}
