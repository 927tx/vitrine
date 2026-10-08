// The lock screen's full-screen artwork as the lyrics, a clip per line (SGLyricsClip.h draws it). A timer
// works out the line being sung and hands the lock screen a new artwork under a new ID each time it
// changes. Nothing is drawn until the lock screen asks for that artwork's video, so lines sung with the
// screen off cost nothing. It rides on Spotify's now playing info as an extra (NowPlayingExtras.h), like
// the moving artwork it takes the place of.
#import <MediaPlayer/MediaPlayer.h>
#import "Core/SGCore.h"
#import "SGLyricsClip.h"
#import "Shared/AnimatedArtwork/AnimatedArtwork.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/Player/NowPlayingExtras.h"
#import "Shared/Player/PlayerState.h"

static const NSTimeInterval kTick = 0.25;
// Past a line's sung end by this much, with the next line at least this far off, the line is let go and
// only the next one shows, dimmed (as the artist row does in LockScreenLyrics.x).
static const NSInteger kBreakMs = 4000;

static NSTimer *sg_timer;
static NSString *sg_track;     // the track the clips are for
static UIImage *sg_cover;      // its cover, once Spotify's now playing info has one for it
static NSString *sg_shownID;   // the artwork handed over last, nil for none; read on sg_queue too
static NSObject *sg_lock;
static dispatch_queue_t sg_queue;   // writes the clips, one at a time
// Draws the previews, apart from the clips: one waiting behind a clip that takes seconds left the lock screen blank.
static dispatch_queue_t sg_previewQueue;

static NSURL *folder(void) {
    NSURL *caches = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    return [caches URLByAppendingPathComponent:@"Vitrine/Lyrics" isDirectory:YES];
}

// The blurred cover, made once per cover and shared by both queues; the caller releases it.
static CGImageRef copyBackdropFor(UIImage *cover, CGSize size) {
    static id made;
    static CGImageRef backdrop;
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    @synchronized (lock) {
        id key = cover ?: NSNull.null;
        if (!backdrop || made != key) {
            CGImageRelease(backdrop);
            backdrop = SGLyricsClipBackdrop(cover.CGImage, size);
            made = key;
        }
        return CGImageRetain(backdrop);
    }
}

static BOOL stillShown(NSString *artworkID) {
    @synchronized (sg_lock) {
        return [artworkID isEqualToString:sg_shownID];
    }
}

static void setShown(NSString *artworkID) {
    @synchronized (sg_lock) {
        sg_shownID = artworkID;
    }
}

// The lock screen's last asks, as absolute times: lines are drawn ahead only while it is showing them, previews and
// clips each by their own asks, as it asks for clips far less often.
static CFAbsoluteTime sg_askedAt, sg_previewAskedAt;
// Previews drawn ahead, by artwork ID.
static NSCache<NSString *, UIImage *> *sg_previews;

static NSURL *clipFile(NSString *artworkID) {
    return [folder() URLByAppendingPathComponent:[artworkID stringByAppendingPathExtension:@"mp4"]];
}

// On sg_previewQueue.
static UIImage *previewFor(NSString *artworkID, NSString *line, NSString *next, UIImage *cover, CGSize size) {
    UIImage *preview = [sg_previews objectForKey:artworkID];
    if (preview) return preview;
    CGImageRef backdrop = copyBackdropFor(cover, size);
    CGImageRef frame = SGLyricsClipFrame(backdrop, line, next, size);
    CGImageRelease(backdrop);
    if (frame) [sg_previews setObject:(preview = [UIImage imageWithCGImage:frame]) forKey:artworkID];
    CGImageRelease(frame);
    return preview;
}

// On sg_queue. A clip drawn ahead is found on disk and handed over at once.
static BOOL writeClip(NSString *artworkID, NSString *line, NSString *next, UIImage *cover, SGLyricsClipStyle style, CGSize size) {
    NSURL *file = clipFile(artworkID);
    if ([NSFileManager.defaultManager fileExistsAtPath:file.path]) return YES;
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    CGImageRef backdrop = copyBackdropFor(cover, size);
    BOOL ok = SGLyricsClipWrite(file, backdrop, line, next, size, style);
    CGImageRelease(backdrop);
    // The first few of a launch, and any that fails: one a line would fill the log.
    static NSUInteger told;
    if (!ok || told++ < 5) SGLog(@"lock lyrics: %@ %@ in %.0f ms", artworkID, ok ? @"written" : @"not written", (CFAbsoluteTimeGetCurrent() - start) * 1000);
    return ok;
}

// The next line's preview and clip, drawn while this one shows: a line change then hands both over at once, where
// drawing them on request left the lock screen on the plain cover for half a second.
static void drawAhead(NSString *artworkID, NSString *line, NSString *next, UIImage *cover, SGLyricsClipStyle style) {
    CFAbsoluteTime time = CFAbsoluteTimeGetCurrent();
    CGSize size = SGLyricsClipSize(SGMotionPixels());
    if (time - sg_previewAskedAt <= 15) dispatch_async(sg_previewQueue, ^{ previewFor(artworkID, line, next, cover, size); });
    if (time - sg_askedAt <= 15) dispatch_async(sg_queue, ^{ writeClip(artworkID, line, next, cover, style, size); });
}

API_AVAILABLE(ios(26.0))
static MPMediaItemAnimatedArtwork *artworkFor(NSString *artworkID, NSString *line, NSString *next, UIImage *cover,
                                              SGLyricsClipStyle style) {
    CGSize size = SGLyricsClipSize(SGMotionPixels());
    return [[MPMediaItemAnimatedArtwork alloc] initWithArtworkID:artworkID
        previewImageRequestHandler:^(CGSize wanted, void (^completion)(UIImage *)) {
            sg_previewAskedAt = CFAbsoluteTimeGetCurrent();
            // One drawn ahead is handed over at once, as Apple asks of a preview; only a miss waits for drawing.
            UIImage *ready = [sg_previews objectForKey:artworkID];
            if (ready) {
                completion(ready);
                return;
            }
            dispatch_async(sg_previewQueue, ^{
                completion(previewFor(artworkID, line, next, cover, size));
                static NSUInteger told;
                if (told++ < 10) SGLog(@"lock lyrics: preview of %@ was not drawn ahead", artworkID);
            });
        }
        videoAssetFileURLRequestHandler:^(CGSize wanted, void (^completion)(NSURL *)) {
            sg_askedAt = CFAbsoluteTimeGetCurrent();
            dispatch_async(sg_queue, ^{
                // A line already sung by the time its turn comes is not drawn.
                if (!stillShown(artworkID)) {
                    completion(nil);
                    return;
                }
                completion(writeClip(artworkID, line, next, cover, style, size) ? clipFile(artworkID) : nil);
            });
        }];
}

static void clear(void) {
    if (!sg_shownID) return;
    setShown(nil);
    SGNowPlayingSetExtras(@"lyrics", nil, nil);
}

static NSString *textAt(NSArray<SGKaraokeLine *> *lines, NSInteger index) {
    return index >= 0 && index < (NSInteger)lines.count ? SGKaraokeLineText(lines[index]) : nil;
}

static void tick(void) {
    if (@available(iOS 26.0, *)) {
        SPTPlayerState *state = SGPlayerState();
        NSString *trackID = SGKaraokePlayingTrack();
        if (!trackID || !state) {
            clear();
            return;
        }
        if (![trackID isEqualToString:sg_track]) {
            sg_track = trackID;
            sg_cover = nil;
            // The IDs name the track, so the last track's clips are never asked for again.
            dispatch_async(sg_queue, ^{
                [NSFileManager.defaultManager removeItemAtURL:folder() error:nil];
                [NSFileManager.defaultManager createDirectoryAtURL:folder() withIntermediateDirectories:YES attributes:nil error:nil];
            });
        }
        NSArray<SGKaraokeLine *> *lines = SGKaraokeLinesForTrack(trackID);
        if (!lines) SGKaraokeRequestLyrics(trackID);
        // Plain text has no line being sung; the lock screen keeps the cover.
        if (!lines.count || SGKaraokeLinesTiming(lines) == SGKaraokeTimingNone) {
            static NSString *told;
            if (lines && ![told isEqualToString:trackID]) {
                told = trackID;
                SGLog(@"lock lyrics: %@ has no synced lines, the lock screen keeps the cover", trackID);
            }
            clear();
            return;
        }
        NSInteger position = SGKaraokePositionMs();
        if (position < 0) return;
        position -= SGKaraokeDelayMs();
        NSInteger index = SGKaraokeLeadLine(lines, position);
        BOOL nextFarOff = index + 1 == (NSInteger)lines.count || lines[index + 1].start - position > kBreakMs;
        BOOL resting = index < 0 || (position > SGKaraokeSungEnd(lines[index]) + kBreakMs && nextFarOff);
        SGLyricsClipStyle style = (SGLyricsClipStyle)SGInt(SGKeyLockScreenLyricsStyle, SGLyricsClipStill);
        NSString *artworkID = [NSString stringWithFormat:@"%@-%ld%@-%ld", trackID, (long)index, resting ? @"r" : @"", (long)style];
        if ([artworkID isEqualToString:sg_shownID]) return;
        // Spotify's request block for its cover, read on main and kept once it is this track's.
        if (!sg_cover) {
            NSDictionary *info = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo;
            MPMediaItemArtwork *artwork = info[MPMediaItemPropertyArtwork];
            if ([info[MPMediaItemPropertyTitle] isEqual:state.track.trackTitle] && [artwork isKindOfClass:MPMediaItemArtwork.class]) {
                sg_cover = [artwork imageWithSize:CGSizeMake(600, 600)];
            }
        }
        // Resting, the line sung is let go and the one coming shows alone.
        NSString *line = resting ? nil : textAt(lines, index), *next = textAt(lines, index + 1);
        if (![sg_shownID hasPrefix:trackID]) SGLog(@"lock lyrics: lines offered for %@", trackID);
        setShown(artworkID);
        SGNowPlayingSetExtras(@"lyrics", @{MPNowPlayingInfoProperty3x4AnimatedArtwork: artworkFor(artworkID, line, next, sg_cover, style)},
                              state.track.trackTitle);
        if (index + 1 < (NSInteger)lines.count) {
            NSString *ahead = [NSString stringWithFormat:@"%@-%ld-%ld", trackID, (long)index + 1, (long)style];
            drawAhead(ahead, textAt(lines, index + 1), textAt(lines, index + 2), sg_cover, style);
        }
    }
}

// Main thread, as everything the timer touches is.
static void setTicking(BOOL on) {
    if (on == (sg_timer != nil)) return;
    if (!on) {
        [sg_timer invalidate];
        sg_timer = nil;
        return;
    }
    sg_timer = [NSTimer timerWithTimeInterval:kTick repeats:YES block:^(NSTimer *t) { tick(); }];
    [NSRunLoop.mainRunLoop addTimer:sg_timer forMode:NSRunLoopCommonModes];
}

@interface SGLyricsArtwork : NSObject <SGPlayerStateObserver>
@end

@implementation SGLyricsArtwork
// A paused player's line does not move, and the lock screen keeps the clip it was left on. Picked or not is read
// each time, so a change on the Lock screen page applies at once.
- (void)playerStateDidChange:(SPTPlayerState *)state {
    BOOL on = SGLockScreenArtwork() == SGLockArtworkLyrics;
    setTicking(on && !state.isPaused);
    if (on) tick();
    else clear();
}
@end

%ctor {
    if (@available(iOS 26.0, *)) {
        sg_lock = [NSObject new];
        sg_queue = dispatch_queue_create("spotifyglass.lockscreen.lyrics", DISPATCH_QUEUE_SERIAL);
        sg_previewQueue = dispatch_queue_create("spotifyglass.lockscreen.lyrics.preview", DISPATCH_QUEUE_SERIAL);
        sg_previews = [NSCache new];
        sg_previews.countLimit = 4;
        static SGLyricsArtwork *observer;
        observer = [SGLyricsArtwork new];
        SGAddPlayerStateObserver(observer);
        // Heard on the writing thread and handed to main without waiting (AGENTS.md).
        static SGLockArtwork choice;
        choice = SGLockScreenArtwork();
        [NSNotificationCenter.defaultCenter addObserverForName:NSUserDefaultsDidChangeNotification object:nil queue:nil
                                                    usingBlock:^(NSNotification *note) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (SGLockScreenArtwork() == choice) return;
                choice = SGLockScreenArtwork();
                SGLog(@"lock lyrics: %@", choice == SGLockArtworkLyrics ? @"picked" : @"no longer picked");
                [observer playerStateDidChange:SGPlayerState()];
            });
        }];
        SGLog(@"lock lyrics: %@, the lock screen takes %@", choice == SGLockArtworkLyrics ? @"on" : @"off",
              MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys);
    }
}
