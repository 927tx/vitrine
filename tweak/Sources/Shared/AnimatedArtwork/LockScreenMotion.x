// The lock screen's artwork moves: the track's Canvas, else Apple Music's animated album cover. iOS 26
// takes a local video through MPMediaItemAnimatedArtwork under one of two now playing keys, 1:1 or 3:4,
// picked here by the video's own shape. It rides on Spotify's now playing info as an extra
// (Shared/Player/NowPlayingExtras.h).
#import <MediaPlayer/MediaPlayer.h>
#import "Core/SGCore.h"
#import "AnimatedArtwork.h"
#import "Shared/Player/NowPlayingExtras.h"
#import "Shared/Player/PlayerState.h"

static NSString *sg_track;   // the URI the artwork is for
static NSString *sg_title;

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

%ctor {
    if (SGLockScreenArtwork() != SGLockArtworkMotion) return;
    if (@available(iOS 26.0, *)) {
        static SGLockScreenMotion *observer;
        observer = [SGLockScreenMotion new];
        SGAddPlayerStateObserver(observer);
        SGLog(@"lock motion: on, the lock screen takes %@", MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys);
    }
}
