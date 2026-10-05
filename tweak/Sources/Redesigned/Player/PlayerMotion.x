// Player redesign: Animated artwork, the track's Canvas or Apple Music's animated cover behind the player,
// the way the Music app draws it. The clip runs edge to edge from the top, sharp to near its foot, where
// it dissolves into its own last rows drawn on down to the bottom of the field, so it ends in its own
// colour rather than on the Fluid field. A blur comes in from the seam (from above the controls for a
// Canvas as tall as the screen) and lies under the controls; behind the lyrics the whole clip is blurred.
// The player's square cover goes while a clip plays, so a track without one keeps its cover over Fluid
// (PlayerField.x keeps the field Fluid for this choice). The player's ⋯ menu switches between Animated
// and Fluid at once (Shared/Player/SpeedPitch.h).
//
// The clip is a subview of the field, not of the background plane: the plane's layout brings the field to
// the front on every pass, and a sibling would end up under it. Each of the field's layout passes attaches
// it (SGRPlayerMotionFieldLaidOut), so a clip that came in before the player first opened, or a field
// Spotify built again, gets it.
//
// The clip holds still when the moving field does (SGRField.m): out of a window, with the app not in front,
// while the player opens or closes, under Reduce Motion and in Low Power Mode.
#import <AVFoundation/AVFoundation.h>
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Shared/AnimatedArtwork/AnimatedArtwork.h"
#import "Shared/Player/PlayerState.h"
#import "Shared/Player/SpeedPitch.h"
#import "Player.h"

// Where the clip starts dissolving into its foot, as a share of its height.
static const CGFloat kFootFrom = 0.9;
// The share of the poster's height, at its bottom, drawn on down as the foot (one pixel row at least).
static const CGFloat kFootRows = 0.01;
// A clip this much taller than wide is a Canvas, drawn to the window's full height.
static const CGFloat kCanvasAspect = 1.5;
// The blur starts at the seam, or this share of the screen down where that is higher, so it is under the
// controls whatever the clip's shape; it is whole kBlurRamp points below its start.
static const CGFloat kBlurByControls = 0.6, kBlurRamp = 96;

@interface SGRPlayerMotionView : UIView
@property (nonatomic) CGFloat screenHeight;
- (void)playFile:(NSURL *)file poster:(UIImage *)poster;
- (void)appear:(BOOL)animated;
- (void)setBlurred:(BOOL)blurred animated:(BOOL)animated;
@end

@implementation SGRPlayerMotionView {
    AVQueuePlayer *_player;
    AVPlayerLooper *_looper;
    UIView *_picture;   // the clip over its foot, faded in as one
    AVPlayerLayer *_clip;
    CAGradientLayer *_clipMask, *_seamMask;
    CALayer *_foot;
    UIVisualEffectView *_seamBlur, *_lyricsBlur;
    CGFloat _aspect;
}

// What fades is the effect views' effect, never their alpha or an ancestor's: UIKit draws a blur under a
// fading alpha or a mask wrongly or not at all.
static UIBlurEffect *blurEffect(void) {
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.userInteractionEnabled = NO;
    self.accessibilityElementsHidden = YES;
    _picture = [[UIView alloc] initWithFrame:frame];
    [self addSubview:_picture];
    _foot = [CALayer layer];
    _foot.contentsGravity = kCAGravityResize;
    [_picture.layer addSublayer:_foot];
    _clip = [AVPlayerLayer layer];
    _clip.videoGravity = AVLayerVideoGravityResizeAspectFill;
    _clipMask = [CAGradientLayer layer];
    _clipMask.colors = @[(id)UIColor.blackColor.CGColor, (id)UIColor.blackColor.CGColor, (id)UIColor.clearColor.CGColor];
    _clipMask.locations = @[@0, @(kFootFrom), @1];
    _clip.mask = _clipMask;
    [_picture.layer addSublayer:_clip];

    _seamBlur = [[UIVisualEffectView alloc] initWithEffect:nil];
    _seamBlur.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    UIView *mask = [UIView new];
    _seamMask = [CAGradientLayer layer];
    _seamMask.colors = @[(id)UIColor.clearColor.CGColor, (id)UIColor.blackColor.CGColor];
    [mask.layer addSublayer:_seamMask];
    _seamBlur.maskView = mask;
    [self addSubview:_seamBlur];
    _lyricsBlur = [[UIVisualEffectView alloc] initWithEffect:nil];
    _lyricsBlur.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [self addSubview:_lyricsBlur];

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (NSNotificationName name in @[UIApplicationDidBecomeActiveNotification, UIApplicationWillResignActiveNotification,
                                      NSProcessInfoPowerStateDidChangeNotification, UIAccessibilityReduceMotionStatusDidChangeNotification]) {
        [center addObserver:self selector:@selector(updateMotionSoon) name:name object:nil];
    }
    SGRObservePlayerTransition(self, ^(id owner) { [owner updateMotion]; }, ^(id owner) { [owner updateMotion]; });
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)setScreenHeight:(CGFloat)height {
    if (height == _screenHeight) return;
    _screenHeight = height;
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    CGFloat width = bounds.size.width, total = MAX(1, bounds.size.height);
    CGFloat screen = _screenHeight > 0 ? _screenHeight : total;
    CGFloat height = round(width * _aspect);
    if (_aspect > kCanvasAspect) height = MAX(height, screen);
    CGFloat seam = round(height * kFootFrom), blurFrom = MIN(seam, round(screen * kBlurByControls));
    _picture.frame = bounds;
    _seamBlur.frame = bounds;
    _seamBlur.maskView.frame = bounds;
    _lyricsBlur.frame = bounds;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _clip.frame = CGRectMake(0, 0, width, height);
    _clipMask.frame = _clip.bounds;
    _foot.frame = CGRectMake(0, seam, width, MAX(0, total - seam));
    _seamMask.frame = bounds;
    _seamMask.locations = @[@(MIN(1, blurFrom / total)), @(MIN(1, (blurFrom + kBlurRamp) / total))];
    [CATransaction commit];
}

- (void)playFile:(NSURL *)file poster:(UIImage *)poster {
    _aspect = poster.size.height / poster.size.width;
    // The poster's last rows, stretched from the seam to the bottom: the clip goes on down in its own colour.
    CGFloat rows = MAX(kFootRows, 1 / MAX(1, poster.size.height * poster.scale));
    _foot.contents = (__bridge id)poster.CGImage;
    _foot.contentsRect = CGRectMake(0, 1 - rows, 1, rows);
    _player = [AVQueuePlayer new];
    _player.muted = YES;
    _player.preventsDisplaySleepDuringVideoPlayback = NO;
    _looper = [AVPlayerLooper playerLooperWithPlayer:_player templateItem:[AVPlayerItem playerItemWithURL:file]];
    _clip.player = _player;
    [self setNeedsLayout];
    [self updateMotion];
}

- (void)appear:(BOOL)animated {
    _picture.alpha = 0;
    void (^apply)(void) = ^{
        self->_picture.alpha = 1;
        self->_seamBlur.effect = blurEffect();
    };
    if (animated) SGRAnimate(SGRMotionFade, apply, nil);
    else apply();
}

- (void)setBlurred:(BOOL)blurred animated:(BOOL)animated {
    void (^apply)(void) = ^{ self->_lyricsBlur.effect = blurred ? blurEffect() : nil; };
    if (animated) SGRAnimate(SGRMotionFade, apply, nil);
    else apply();
}

// The power state is reported off the main thread.
- (void)updateMotionSoon {
    dispatch_async(dispatch_get_main_queue(), ^{ [self updateMotion]; });
}

// A locked phone keeps the player in its window, so being in front counts as much as being in one.
- (void)updateMotion {
    BOOL front = UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    BOOL may = self.window && front && !SGRPlayerIsTransitioning() && !SGRReduceMotion() && !NSProcessInfo.processInfo.lowPowerModeEnabled;
    if (may) [_player play];
    else [_player pause];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self updateMotion];
}

@end

static SGRPlayerMotionView *sg_motion;
static NSString *sg_track;
// The list the empty mask went on, so it comes off even while the player is closed and the list cannot
// be found.
static __weak CALayer *sg_maskedCovers;

// The clip from the top of the field, as wide as it is, its foot down to the bottom of the field's bleed.
static void layOut(void) {
    SGRArtworkField *field = SGRPlayerField();
    if (!sg_motion || !field) return;
    if (sg_motion.superview != field) [field addSubview:sg_motion];
    CGSize size = field.bounds.size;
    CGFloat screen = field.window.bounds.size.height ?: size.height;
    CGRect frame = CGRectMake(0, 0, size.width, MAX(size.height, screen) + field.bleed.bottom);
    if (!CGRectEqualToRect(sg_motion.frame, frame)) sg_motion.frame = frame;
    sg_motion.screenHeight = screen;
}

// An empty mask rather than alpha: the covers still take the swipe that changes track, and the lyrics,
// which fade the list by its alpha as they come and go, cannot bring the cover back.
static void setCoverShown(BOOL shown) {
    if (shown) {
        sg_maskedCovers.mask = nil;
        sg_maskedCovers = nil;
        return;
    }
    CALayer *covers = SGRPlayerCoverList().layer;
    if (!covers || covers.mask) return;
    covers.mask = [CALayer layer];
    sg_maskedCovers = covers;
}

void SGRPlayerMotionFieldLaidOut(void) {
    layOut();
    setCoverShown(sg_motion == nil);
}

BOOL SGRPlayerMotionShowing(void) {
    return sg_motion != nil;
}

static void clear(void) {
    [sg_motion removeFromSuperview];
    sg_motion = nil;
    setCoverShown(YES);
}

static void show(NSString *track, NSURL *file) {
    if (!file || ![track isEqualToString:sg_track]) return;
    SGMotionPoster(file, ^(UIImage *poster) {
        if (!poster || poster.size.width <= 0 || ![track isEqualToString:sg_track]) return;
        clear();
        sg_motion = [[SGRPlayerMotionView alloc] initWithFrame:CGRectZero];
        [sg_motion playFile:file poster:poster];
        layOut();
        [sg_motion setBlurred:SGRPlayerLyricsOpen() animated:NO];
        [sg_motion appear:sg_motion.window != nil];
        setCoverShown(NO);
        SGLog(@"redesign player: animated artwork %@, %.0fx%.0f", file.lastPathComponent, poster.size.width, poster.size.height);
    });
}

void SGRPlayerMotionLyricsChanged(void) {
    [sg_motion setBlurred:SGRPlayerLyricsOpen() animated:sg_motion.window != nil];
}

@interface SGRPlayerMotionWatcher : NSObject <SGPlayerStateObserver>
@end

@implementation SGRPlayerMotionWatcher
- (void)playerStateDidChange:(SPTPlayerState *)state {
    NSString *track = SGURIString(state.track.URI);
    if (!track || [track isEqualToString:sg_track]) return;
    sg_track = track;
    clear();
    // Read on every track, since the ⋯ menu switches it.
    if (SGRPlayerBackground() != SGRPlayerBackgroundAnimated) return;
    NSDictionary *metadata = [state.track.metadata isKindOfClass:NSDictionary.class] ? state.track.metadata : nil;
    id type = metadata[@"canvas.type"], address = metadata[@"canvas.url"];
    BOOL video = [type isKindOfClass:NSString.class] && [type rangeOfString:@"video" options:NSCaseInsensitiveSearch].location != NSNotFound;
    NSURL *canvas = video && [address isKindOfClass:NSString.class] ? [NSURL URLWithString:address] : nil;
    NSString *artist = state.track.artistName, *album = metadata[@"album_title"];
    CGFloat pixels = SGMotionPixels();
    void (^apple)(void) = ^{
        SGMotionAlbumCover(artist, album, SGMotionTall, pixels, ^(NSURL *file) { show(track, file); });
    };
    static NSUInteger logged;
    if (logged++ < 3) SGLog(@"redesign player: canvas %@ (%@)", canvas ? @"found" : @"none", type ?: @"no type");
    if (!canvas) {
        apple();
        return;
    }
    SGMotionFile(canvas, ^(NSURL *file) {
        if (file) show(track, file);
        else apple();
    });
}
@end

static SGRPlayerMotionWatcher *sg_watcher;

#pragma mark - the ⋯ menu's switch (Shared/Player/SpeedPitch.h)

// Fluid and Animated share the field, so the menu moves between the two without a restart. The other
// backgrounds are a field of another kind, chosen on the Now playing page.
BOOL SGPlayerMenuOffersAnimatedArtwork(void) {
    if (!sg_watcher) return NO;
    SGRPlayerBackgroundKind background = SGRPlayerBackground();
    return background == SGRPlayerBackgroundFluid || background == SGRPlayerBackgroundAnimated;
}

BOOL SGPlayerMenuAnimatedArtwork(void) {
    return SGRPlayerBackground() == SGRPlayerBackgroundAnimated;
}

void SGPlayerMenuSetAnimatedArtwork(BOOL on) {
    if (!SGPlayerMenuOffersAnimatedArtwork() || on == SGPlayerMenuAnimatedArtwork()) return;
    SGSetInt(SGRKeyPlayerBackground, on ? SGRPlayerBackgroundAnimated : SGRPlayerBackgroundFluid);
    SGLog(@"redesign player: animated artwork switched %@ from the menu", on ? @"on" : @"off");
    // The playing track is let go, and looked up again when switched on.
    sg_track = nil;
    clear();
    [sg_watcher playerStateDidChange:SGPlayerState()];
}

%ctor {
    if (!SGRedesignedUI()) return;
    SGRPlayerBackgroundKind background = SGRPlayerBackground();
    if (background != SGRPlayerBackgroundFluid && background != SGRPlayerBackgroundAnimated) return;
    sg_watcher = [SGRPlayerMotionWatcher new];
    SGAddPlayerStateObserver(sg_watcher);
}
