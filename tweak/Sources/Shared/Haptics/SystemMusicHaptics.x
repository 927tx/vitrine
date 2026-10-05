// iOS's own Music Haptics for Spotify: the system plays a haptic track along with a recording it knows by
// its ISRC, in the background and on the lock screen too, for an app that declares MusicHapticsSupported
// (plist/liquid-glass.plist) and names the ISRC in its now playing info. Spotify names none, so the song is
// looked up in Apple Music's catalog and its ISRC rides on Spotify's info as an extra. Nothing is asked
// while Music Haptics is off in Settings > Accessibility, and turning it on there looks the playing song up
// at once. When Apple has a haptic track for the song, the mod's own Music Haptics (MusicHaptics.x) stands
// down until the next one, so the two never play over each other.
#import <MediaAccessibility/MediaAccessibility.h>
#import <MediaPlayer/MediaPlayer.h>
#import "Core/SGCore.h"
#import "Shared/AnimatedArtwork/AnimatedArtwork.h"
#import "Shared/Player/NowPlayingExtras.h"
#import "Shared/Player/PlayerState.h"
#import "Haptics.h"

API_AVAILABLE(ios(18.0))
@interface SGSystemMusicHaptics : NSObject <SGPlayerStateObserver>
- (void)follow:(SPTPlayerState *)state;
@end

@implementation SGSystemMusicHaptics {
    NSString *_track;
}

- (void)playerStateDidChange:(SPTPlayerState *)state {
    NSString *track = SGURIString(state.track.URI);
    if (!track || [track isEqualToString:_track]) return;
    [self follow:state];
}

- (void)follow:(SPTPlayerState *)state {
    NSString *track = SGURIString(state.track.URI);
    _track = track;
    SGNowPlayingSetExtras(@"haptics", nil, nil);
    SGMusicHapticsSetSystemPlaying(NO);
    MAMusicHapticsManager *manager = MAMusicHapticsManager.sharedManager;
    // Only a song can have a recording code: an episode or an ad is not looked up.
    if (!manager.isActive || !([track hasPrefix:@"spotify:track:"] || [track hasPrefix:@"spotify:local:"])) return;
    NSString *title = state.track.trackTitle;
    SGMotionSongISRC(state.track.artistName, title, ^(NSString *isrc) {
        if (!isrc || ![track isEqualToString:self->_track]) return;
        SGNowPlayingSetExtras(@"haptics", @{MPNowPlayingInfoPropertyInternationalStandardRecordingCode: isrc}, title);
        static NSUInteger logged;
        if (logged++ < 3) SGLog(@"music haptics: %@ named for iOS's Music Haptics", isrc);
        [manager checkHapticTrackAvailabilityForMediaMatchingCode:isrc completionHandler:^(BOOL available) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!available || ![track isEqualToString:self->_track] || !manager.isActive) return;
                SGMusicHapticsSetSystemPlaying(YES);
            });
        }];
    });
}

@end

%ctor {
    if (@available(iOS 18.0, *)) {
        static SGSystemMusicHaptics *watcher;
        watcher = [SGSystemMusicHaptics new];
        SGAddPlayerStateObserver(watcher);
        [NSNotificationCenter.defaultCenter addObserverForName:MAMusicHapticsManagerActiveStatusDidChangeNotification object:nil
                                                         queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            SGLog(@"music haptics: iOS's Music Haptics %@", MAMusicHapticsManager.sharedManager.isActive ? @"on" : @"off");
            [watcher follow:SGPlayerState()];
        }];
    }
}
