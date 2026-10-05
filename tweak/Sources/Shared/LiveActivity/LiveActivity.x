// Polls the player and sends the activity a new state only when what its view shows changes: the
// lyrics' line, what is up next, the control menu's tab, track, shuffle, repeat or sleep timer, or a
// pause. The view is read on every tick, so picking another one shows within a tick. Spotify keeps
// playing in the background, so the timer keeps running there too, and with it the sleep timer.
// The activity is started only while the app is in front, the one place ActivityKit allows it.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <MediaPlayer/MediaPlayer.h>
#import "Core/SGCore.h"
#import "Shared/Player/PlayerState.h"
#import "Headers/SPTPlayer.h"
#import "Shared/Lyrics/Lyrics.h"
#import "LiveActivity.h"

API_AVAILABLE(ios(17.0))
@interface SGLiveActivityBridge : NSObject
@property (class, nonatomic, readonly) BOOL isShowing;
+ (void)showWithView:(NSInteger)view paused:(BOOL)paused line:(NSString *)line nextLine:(NSString *)nextLine
              titles:(NSArray<NSString *> *)titles artists:(NSArray<NSString *> *)artists uris:(NSArray<NSString *> *)uris
                 tab:(NSInteger)tab title:(NSString *)title artist:(NSString *)artist shuffle:(BOOL)shuffle repeatMode:(NSInteger)repeatMode
            timerEnd:(NSDate *)timerEnd timerEndOfTrack:(BOOL)timerEndOfTrack
                tint:(NSString *)tint trackStart:(NSDate *)trackStart trackEnd:(NSDate *)trackEnd pausedAt:(NSNumber *)pausedAt
         translation:(NSString *)translation cover:(NSData *)cover textSize:(NSInteger)textSize;
+ (void)end;
@end

// The control menu's tabs, SGLyricsAttributes.Tab's values.
typedef NS_ENUM(NSInteger, SGLiveActivityTab) {
    SGLiveActivityTabControls = 0,
    SGLiveActivityTabQueue,
    SGLiveActivityTabTimer,
};

static const NSTimeInterval kTick = 0.25;
// Paused, the only thing on the card that still moves is the sleep timer, and a slower tick catches
// its end well within the second the card shows. Four ticks a second for a still card is a wake up
// eighty times a minute for a picture that does not change.
static const NSTimeInterval kPausedTick = 1;
// Past a line's sung end by this much, with the next line at least this far off, the line gives way to a note.
static const NSInteger kBreakMs = 4000;
// Seconds between attempts to start one, so a refused request (activities turned off) is not retried every tick.
static const NSTimeInterval kStartRetry = 10;
// Tracks up next: the queue view shows four on the lock screen (three in the Dynamic Island), the
// control menu's queue tab three.
static const NSUInteger kUpNextQueue = 4;
static const NSUInteger kUpNextPanel = 3;
// The end of track timer pauses this close to the end, so the next track never starts.
static const NSInteger kEndOfTrackMs = 500;
// The cover goes to the card in the state itself, which ActivityKit caps at 4 KB with everything else in
// it and encodes as JSON, the cover in base64: this many bytes of JPEG come to about 1.9 KB of it.
static const NSUInteger kCoverBytes = 1400;
// A new state takes about this long to show on the card, so the line is picked this far ahead and
// lands as it is sung rather than a beat after.
static const NSInteger kRenderLeadMs = 800;
// A track start this close to the one sent is the same start, rounded the other way.
static const NSTimeInterval kStartSlack = 1.5;
// The card's background is at most this light, as relative luminance (about #383838), so every white on
// it keeps 4.5:1: the dimmest, at 0.6, comes to about 5.3:1 there, the line itself over 11:1.
static const double kTintLuminance = 0.04;

static NSTimer *sg_timer;
static NSTimeInterval sg_tickEvery;
static NSString *sg_shown;
static NSString *sg_missingLyrics;
static NSDate *sg_lastStart;
static SGLiveActivityTab sg_tab;
// The sleep timer: an end, or the end of the track it was set on.
static NSDate *sg_sleepEnd;
static NSString *sg_sleepTrack;

static void tick(void) API_AVAILABLE(ios(17.0));

// An NSTimer cannot be asked to change pace, so changing it is putting one down and another up.
static void startTimer(NSTimeInterval every) API_AVAILABLE(ios(17.0)) {
    [sg_timer invalidate];
    sg_tickEvery = every;
    sg_timer = [NSTimer timerWithTimeInterval:every repeats:YES block:^(NSTimer *t) { tick(); }];
    [NSRunLoop.mainRunLoop addTimer:sg_timer forMode:NSRunLoopCommonModes];
}

// Sends `shown`, what the activity is to show as one string, unless it is showing that already; starts
// the activity when there is none and the app is in front.
static void send(NSString *shown, void (^show)(void)) API_AVAILABLE(ios(17.0)) {
    if (SGLiveActivityBridge.isShowing) {
        if ([shown isEqualToString:sg_shown]) return;
    } else {
        if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
        if (sg_lastStart && -sg_lastStart.timeIntervalSinceNow < kStartRetry) return;
        sg_lastStart = [NSDate date];
    }
    sg_shown = shown;
    show();
}

// A track's URI as a string; the player hands out NSURL or NSString.
static NSString *uriOf(SPTPlayerTrack *track) {
    id uri = track.URI;
    if ([uri isKindOfClass:NSURL.class]) return [(NSURL *)uri absoluteString];
    return [uri isKindOfClass:NSString.class] ? uri : nil;
}

// The state's tracks up next, skipping what is not a track or has no title or URI.
static NSArray<SPTPlayerTrack *> *upNext(SPTPlayerState *state) {
    NSMutableArray<SPTPlayerTrack *> *tracks = [NSMutableArray array];
    id future = [state respondsToSelector:@selector(future)] ? state.future : nil;
    for (id track in [future isKindOfClass:NSArray.class] ? future : @[]) {
        if (![track isKindOfClass:objc_getClass("SPTPlayerTrack")]) continue;
        if (![(SPTPlayerTrack *)track trackTitle].length || !uriOf(track)) continue;
        [tracks addObject:track];
    }
    return tracks;
}

// 0 off, 1 the playlist or album, 2 the track.
static NSInteger repeatModeOf(SPTPlayerOptions *options) {
    return options.repeatingTrack ? 2 : options.repeatingContext ? 1 : 0;
}

// The line being sung and the one after it; before the first line, between lines and without lyrics
// at all, a note holds the place.
static NSString *lyricsLine(NSString *trackID, NSString **next, NSString **translation) {
    NSArray<SGKaraokeLine *> *lines = SGKaraokeLinesForTrack(trackID);
    if (!lines) {
        SGKaraokeRequestLyrics(trackID);
        if (trackID && ![trackID isEqualToString:sg_missingLyrics]) {
            sg_missingLyrics = trackID;
            SGLog(@"live activity: no lyrics yet for %@", trackID);
        }
    }
    // Plain text has no line being sung: the note, as for a track with no lyrics.
    if (lines && SGKaraokeLinesTiming(lines) == SGKaraokeTimingNone) lines = nil;
    NSInteger position = SGKaraokePositionMs();
    if (position >= 0 && !SGPlayerState().isPaused) position += kRenderLeadMs;
    // With two voices at once, the one that came in first, and the one singing over it as the next.
    NSInteger index = SGKaraokeLeadLine(lines, position);
    *next = index + 1 < (NSInteger)lines.count ? SGKaraokeLineText(lines[index + 1]) : @"";
    if (index < 0) return @"♪";
    SGKaraokeLine *current = lines[index];
    BOOL nextFarOff = index + 1 == (NSInteger)lines.count || lines[index + 1].start - position > kBreakMs;
    if (position > current.end + kBreakMs && nextFarOff) return @"♪";
    *translation = current.translation;
    return SGKaraokeLineText(current);
}

// The cover for the card, read once a track from Spotify's now playing artwork: its colour, darkened so
// white text keeps its contrast, and a small JPEG of it. At a track change the player moves a moment
// before Spotify hands over the new artwork, so it is read only once the now playing title is the
// track's (as Shared/LockScreenLyrics/LyricsArtwork.x does); until then the last track's stays. Spotify
// hands over a placeholder first and the cover after it, a new artwork object each time, so a new
// object for the same track is read again.
static NSString *sg_artTrack, *sg_tint;
static NSData *sg_cover;
static __weak id sg_artObject;

// The cover at the largest of a few sizes whose JPEG fits kCoverBytes, drawn in device RGB so no colour
// profile rides along; nil when none fits.
static NSData *coverJPEG(CGImageRef image) {
    for (NSNumber *side in @[@56, @48, @40, @32]) {
        size_t pixels = side.unsignedIntegerValue;
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGContextRef context = CGBitmapContextCreate(NULL, pixels, pixels, 8, 0, space, (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
        CGColorSpaceRelease(space);
        if (!context) return nil;
        CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
        CGContextDrawImage(context, CGRectMake(0, 0, pixels, pixels), image);
        CGImageRef small = CGBitmapContextCreateImage(context);
        CGContextRelease(context);
        NSData *data = small ? UIImageJPEGRepresentation([UIImage imageWithCGImage:small], 0.5) : nil;
        CGImageRelease(small);
        if (data.length && data.length <= kCoverBytes) return data;
    }
    return nil;
}

// A channel of 0 to 255 as light, the sRGB curve undone.
static double linear(double channel) {
    channel /= 255;
    return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4);
}

// The card's background, RRGGBB: at most 0.55 of the cover's colour, the rest black, and darker still
// until it is no lighter than kTintLuminance. At a fixed 0.55 a white or yellow cover came out #8C8C8C.
static NSString *tintOf(double red, double green, double blue) {
    double keep = 0.55;
    while (keep > 0 && 0.2126 * linear(red * keep) + 0.7152 * linear(green * keep) + 0.0722 * linear(blue * keep) > kTintLuminance) keep -= 0.01;
    keep = MAX(keep, 0);
    return [NSString stringWithFormat:@"%02X%02X%02X", (int)(red * keep), (int)(green * keep), (int)(blue * keep)];
}

static void readArtwork(SPTPlayerState *state, NSString *trackID) {
    if (!trackID) return;
    NSDictionary *info = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo;
    if (![info[MPMediaItemPropertyTitle] isEqual:state.track.trackTitle]) return;
    MPMediaItemArtwork *artwork = info[MPMediaItemPropertyArtwork];
    if ([trackID isEqualToString:sg_artTrack] && artwork == sg_artObject) return;
    sg_artObject = artwork;
    UIImage *image = [artwork isKindOfClass:MPMediaItemArtwork.class] ? [artwork imageWithSize:CGSizeMake(64, 64)] : nil;
    if (!image.CGImage) return;
    unsigned char pixel[4] = {0};
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixel, 1, 1, 8, 4, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    if (!context) return;
    CGContextSetInterpolationQuality(context, kCGInterpolationMedium);
    CGContextDrawImage(context, CGRectMake(0, 0, 1, 1), image.CGImage);
    CGContextRelease(context);
    sg_artTrack = trackID;
    sg_tint = tintOf(pixel[0], pixel[1], pixel[2]);
    sg_cover = coverJPEG(image.CGImage);
    static int logged;
    if (logged++ < 6) SGLog(@"live activity: cover of %@, %lu bytes", trackID, (unsigned long)sg_cover.length);
}

static void clearSleepTimer(void) {
    sg_sleepEnd = nil;
    sg_sleepTrack = nil;
}

// Pauses once the sleep timer is up: at its end, or just before the end of the track it was set on
// (on the next track, should the length not be known).
static void checkSleepTimer(id<SPTPlayer> player, SPTPlayerState *state, NSString *trackID) {
    BOOL up = NO;
    if (sg_sleepEnd) {
        up = sg_sleepEnd.timeIntervalSinceNow <= 0;
    } else if (sg_sleepTrack) {
        double duration = [state respondsToSelector:@selector(duration)] ? state.duration : 0;
        NSInteger position = SGKaraokePositionMs();
        up = ![trackID isEqualToString:sg_sleepTrack]
            || (duration > 0 && position >= 0 && duration * 1000 - position < kEndOfTrackMs);
    }
    if (!up) return;
    clearSleepTimer();
    if (!state.isPaused) [player pause:nil];
    SGLog(@"live activity: sleep timer up, paused");
}

static void tick(void) API_AVAILABLE(ios(17.0)) {
    id<SPTPlayer> player = SGKaraokePlayer();
    SPTPlayerState *state = player.state;
    SPTPlayerTrack *track = state.track;
    if (!track.trackTitle.length) return;
    NSString *trackID = SGKaraokePlayingTrack();
    checkSleepTimer(player, state, trackID);

    NSInteger view = SGInt(SGKeyLiveActivityView, SGLiveActivityLyrics);
    BOOL paused = state.isPaused;
    NSTimeInterval every = paused ? kPausedTick : kTick;
    if (sg_timer && sg_tickEvery != every) startTimer(every);
    NSString *line = @"", *next = @"", *translation = nil;
    if (view == SGLiveActivityLyrics) line = lyricsLine(trackID, &next, &translation);
    if (!SGFlag(SGKeyLiveActivityTranslation, NO)) translation = nil;
    NSInteger textSize = view == SGLiveActivityLyrics ? SGInt(SGKeyLiveActivityTextSize, SGLiveActivityTextMedium) : SGLiveActivityTextMedium;
    readArtwork(state, trackID);
    NSString *tint = sg_tint;
    NSData *cover = sg_cover;
    // The bar runs by itself from where the track started; paused, it holds at the share played.
    double duration = [state respondsToSelector:@selector(duration)] ? state.duration : 0;
    NSInteger position = SGKaraokePositionMs();
    NSDate *trackStart = nil, *trackEnd = nil;
    NSNumber *pausedAt = nil;
    static NSDate *sentStart;
    if (duration > 0 && position >= 0) {
        double played = position / 1000.0;
        trackStart = [NSDate dateWithTimeIntervalSinceNow:-played];
        trackStart = [NSDate dateWithTimeIntervalSince1970:round(trackStart.timeIntervalSince1970)];
        // Playing, the start only moves on a seek or a new track; paused, it creeps on with the clock and
        // the bar is drawn from pausedAt, so it is left out of what tells a new state.
        if (paused) pausedAt = @(MIN(1, played / duration));
        else if (sentStart && fabs([trackStart timeIntervalSinceDate:sentStart]) < kStartSlack) trackStart = sentStart;
        else sentStart = trackStart;
        trackEnd = [trackStart dateByAddingTimeInterval:duration];
    }

    NSMutableArray<NSString *> *titles = [NSMutableArray array], *artists = [NSMutableArray array], *uris = [NSMutableArray array];
    if (view != SGLiveActivityLyrics) {
        NSUInteger limit = view == SGLiveActivityQueue ? kUpNextQueue : kUpNextPanel;
        for (SPTPlayerTrack *upcoming in upNext(state)) {
            if (titles.count == limit) break;
            [titles addObject:upcoming.trackTitle];
            [artists addObject:upcoming.artistName ?: @""];
            [uris addObject:uriOf(upcoming)];
        }
    }

    BOOL panel = view == SGLiveActivityPanel;
    // Every view sends the track, which Apple Watch and CarPlay show beside the cover.
    NSString *title = track.trackTitle ?: @"", *artist = track.artistName ?: @"";
    BOOL shuffle = panel && state.options.shufflingContext;
    NSInteger repeatMode = panel ? repeatModeOf(state.options) : 0;
    NSInteger tab = panel ? sg_tab : 0;
    NSDate *sleepEnd = sg_sleepEnd;
    BOOL endOfTrack = sg_sleepTrack != nil;

    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithObjects:@(view).stringValue, paused ? @"1" : @"0", line, next,
        @(tab).stringValue, title, artist, shuffle ? @"1" : @"0", @(repeatMode).stringValue,
        @((long long)sleepEnd.timeIntervalSince1970).stringValue, endOfTrack ? @"1" : @"0", tint ?: @"", translation ?: @"",
        paused ? @"" : @((long long)trackStart.timeIntervalSince1970).stringValue, paused ? @(round(pausedAt.doubleValue * 100)).stringValue : @"",
        cover ? sg_artTrack : @"", @(textSize).stringValue, nil];
    for (NSUInteger i = 0; i < titles.count; i++) [parts addObject:[NSString stringWithFormat:@"%@\t%@\t%@", titles[i], artists[i], uris[i]]];
    send([parts componentsJoinedByString:@"\n"], ^{
        [SGLiveActivityBridge showWithView:view paused:paused line:line nextLine:next titles:titles artists:artists uris:uris
                                        tab:tab title:title artist:artist shuffle:shuffle repeatMode:repeatMode
                                   timerEnd:sleepEnd timerEndOfTrack:endOfTrack
                                       tint:tint trackStart:trackStart trackEnd:trackEnd pausedAt:pausedAt translation:translation
                                      cover:cover textSize:textSize];
    });
}

// A tap on a track up next: skips ahead to it, found again by its URI in case the queue moved since
// the card was drawn.
static void playQueued(NSString *uri) {
    id<SPTPlayer> player = SGKaraokePlayer();
    SPTPlayerTrack *target = nil;
    for (SPTPlayerTrack *track in upNext(player.state)) {
        if ([uriOf(track) isEqualToString:uri]) { target = track; break; }
    }
    if (!target || ![player respondsToSelector:@selector(skipToNextTrackWithOptions:track:)]) {
        SGLog(@"live activity: cannot play %@ (in the queue: %@, player %@)", uri, target ? @"yes" : @"no", player ? NSStringFromClass([player class]) : @"nil");
        return;
    }
    id result = [player skipToNextTrackWithOptions:nil track:target];
    SGLog(@"live activity: play %@ -> %@", uri, result);
}

// A tap in the control menu, one of SGLiveActivityActionIntent's actions.
static void runAction(NSString *action) {
    id<SPTPlayer> player = SGKaraokePlayer();
    SPTPlayerState *state = player.state;
    NSArray<NSString *> *parts = [action componentsSeparatedByString:@":"];
    NSString *name = parts.firstObject, *value = parts.count > 1 ? parts[1] : @"";
    id result = nil;
    if ([name isEqualToString:@"tab"]) {
        sg_tab = MAX(SGLiveActivityTabControls, MIN(SGLiveActivityTabTimer, value.integerValue));
    } else if ([name isEqualToString:@"toggle"]) {
        result = state.isPaused ? [player resume:nil] : [player pause:nil];
    } else if ([name isEqualToString:@"previous"]) {
        result = [player skipToPreviousTrackWithOptions:nil];
    } else if ([name isEqualToString:@"next"]) {
        result = [player skipToNextTrackWithOptions:nil];
    } else if ([name isEqualToString:@"shuffle"]) {
        result = [player setShufflingContext:!state.options.shufflingContext];
    } else if ([name isEqualToString:@"repeat"]) {
        // Off, then the playlist or album, then the track, then off again, the way Spotify's button goes.
        switch (repeatModeOf(state.options)) {
            case 0: result = [player setRepeatingContext:YES]; break;
            case 1: result = [player setRepeatingTrack:YES]; break;
            default:
                [player setRepeatingTrack:NO];
                result = [player setRepeatingContext:NO];
        }
    } else if ([name isEqualToString:@"timer"]) {
        if ([value isEqualToString:@"cancel"]) {
            clearSleepTimer();
        } else if ([value isEqualToString:@"track"]) {
            clearSleepTimer();
            sg_sleepTrack = SGKaraokePlayingTrack();
        } else if ([value isEqualToString:@"add"]) {
            NSDate *from = sg_sleepEnd && sg_sleepEnd.timeIntervalSinceNow > 0 ? sg_sleepEnd : [NSDate date];
            sg_sleepEnd = [from dateByAddingTimeInterval:15 * 60];
        } else if (value.integerValue > 0) {
            clearSleepTimer();
            sg_sleepEnd = [NSDate dateWithTimeIntervalSinceNow:value.integerValue * 60];
        }
    } else {
        SGLog(@"live activity: unknown action %@", action);
        return;
    }
    SGLog(@"live activity: %@ -> %@", action, result);
}

void SGSetLiveActivityEnabled(BOOL on) {
    if (@available(iOS 17.0, *)) {
        [sg_timer invalidate];
        sg_timer = nil;
        sg_shown = nil;
        sg_lastStart = nil;
        clearSleepTimer();
        if (!on) {
            [SGLiveActivityBridge end];
            SGLog(@"live activity: off");
            return;
        }
        static dispatch_once_t observing;
        dispatch_once(&observing, ^{
            NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
            [center addObserverForName:@"SGLiveActivityPlay" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                if ([note.object isKindOfClass:NSString.class]) playQueued(note.object);
            }];
            // The new state goes out at once rather than on the next tick, the card being slow enough to redraw.
            [center addObserverForName:@"SGLiveActivityAction" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                if (![note.object isKindOfClass:NSString.class]) return;
                runAction(note.object);
                if (sg_timer) tick();
            }];
        });
        startTimer(kTick);
        SGLog(@"live activity: on");
    }
}

%ctor {
    if (@available(iOS 17.0, *)) {
        // It was the redesign's alone until it moved to Shared/; whoever had it on keeps it on.
        SGMigrateKey(SGKeyLiveActivityWas, SGKeyLiveActivity);
        SGMigrateKey(SGKeyLiveActivityViewWas, SGKeyLiveActivityView);
        BOOL on = SGFlag(SGKeyLiveActivity, NO);
        // Off, one left from a launch before the switch went off is ended.
        dispatch_async(dispatch_get_main_queue(), ^{
            if (on) SGSetLiveActivityEnabled(YES);
            else [SGLiveActivityBridge end];
        });
    }
}
