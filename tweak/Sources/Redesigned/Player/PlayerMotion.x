// Player redesign: Animated artwork, the track's Canvas or Apple Music's animated cover behind the player,
// the way the Music app draws it. The clip runs edge to edge from the top, sharp to near its foot, where
// it dissolves into the Fluid field under it (PlayerField.x keeps the field Fluid for this choice). The
// player's square cover goes while a clip plays, so a track without one keeps its cover. Behind the
// lyrics the clip is blurred.
//
// The clip is a subview of the field, not of the background plane: the plane's layout brings the field to
// the front on every pass, and a sibling would end up under it.
#import <AVFoundation/AVFoundation.h>
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Shared/AnimatedArtwork/AnimatedArtwork.h"
#import "Shared/Player/PlayerState.h"
#import "Player.h"

// Where the clip starts dissolving, as a share of its height.
static const CGFloat kFootFrom = 0.78;
// A clip this much taller than wide is a Canvas, drawn to the window's full height.
static const CGFloat kCanvasAspect = 1.5;

static void setCoverShown(BOOL shown);

@interface SGRPlayerMotionView : UIView
- (void)playFile:(NSURL *)file aspect:(CGFloat)aspect;
- (void)setBlurred:(BOOL)blurred animated:(BOOL)animated;
@end

@implementation SGRPlayerMotionView {
    AVQueuePlayer *_player;
    AVPlayerLooper *_looper;
    CAGradientLayer *_foot;
    UIVisualEffectView *_blur;
    CGFloat _aspect;
}

+ (Class)layerClass {
    return AVPlayerLayer.class;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.userInteractionEnabled = NO;
    self.accessibilityElementsHidden = YES;
    ((AVPlayerLayer *)self.layer).videoGravity = AVLayerVideoGravityResizeAspectFill;
    _foot = [CAGradientLayer layer];
    _foot.colors = @[(id)UIColor.blackColor.CGColor, (id)UIColor.blackColor.CGColor, (id)UIColor.clearColor.CGColor];
    _foot.locations = @[@0, @(kFootFrom), @1];
    self.layer.mask = _foot;
    _blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
    _blur.alpha = 0;
    _blur.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [self addSubview:_blur];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _foot.frame = self.bounds;
    [CATransaction commit];
    _blur.frame = self.bounds;
}

- (void)playFile:(NSURL *)file aspect:(CGFloat)aspect {
    _aspect = aspect;
    _player = [AVQueuePlayer new];
    _player.muted = YES;
    _player.preventsDisplaySleepDuringVideoPlayback = NO;
    _looper = [AVPlayerLooper playerLooperWithPlayer:_player templateItem:[AVPlayerItem playerItemWithURL:file]];
    ((AVPlayerLayer *)self.layer).player = _player;
    if (self.window) [_player play];
}

- (CGFloat)aspect {
    return _aspect;
}

- (void)setBlurred:(BOOL)blurred animated:(BOOL)animated {
    void (^apply)(void) = ^{ self->_blur.alpha = blurred ? 1 : 0; };
    if (animated) SGRAnimate(SGRMotionFade, apply, nil);
    else apply();
}

// Off screen, the clip stops decoding. A clip that arrived while the player was closed hides the cover
// once the player opens.
- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window) {
        [_player play];
        setCoverShown(NO);
    } else {
        [_player pause];
    }
}

@end

static SGRPlayerMotionView *sg_motion;
static NSString *sg_track;

// The clip from the top of the field, as wide as it is: a Canvas down to the window's foot.
static void layOut(void) {
    SGRArtworkField *field = SGRPlayerField();
    if (!sg_motion || !field) return;
    if (sg_motion.superview != field) [field addSubview:sg_motion];
    CGFloat width = field.bounds.size.width, aspect = [(id)sg_motion aspect];
    CGFloat height = round(width * aspect);
    if (aspect > kCanvasAspect) height = MAX(height, field.window.bounds.size.height ?: height);
    CGRect frame = CGRectMake(0, 0, width, height);
    if (!CGRectEqualToRect(sg_motion.frame, frame)) sg_motion.frame = frame;
    // The field's width follows the plane's; the height was set for this clip.
    sg_motion.autoresizingMask = UIViewAutoresizingFlexibleWidth;
}

// An empty mask rather than alpha: the covers still take the swipe that changes track, and the lyrics,
// which fade the list by its alpha as they come and go, cannot bring the cover back.
static void setCoverShown(BOOL shown) {
    CALayer *covers = SGRPlayerCoverList().layer;
    if (!covers || (covers.mask == nil) == shown) return;
    covers.mask = shown ? nil : [CALayer layer];
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
        sg_motion.alpha = 0;
        [sg_motion playFile:file aspect:poster.size.height / poster.size.width];
        layOut();
        [sg_motion setBlurred:SGRPlayerLyricsOpen() animated:NO];
        BOOL animated = sg_motion.window != nil;
        void (^appear)(void) = ^{
            sg_motion.alpha = 1;
            setCoverShown(NO);
        };
        if (animated) SGRAnimate(SGRMotionFade, appear, nil);
        else appear();
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

%ctor {
    if (!SGRedesignedUI() || SGRPlayerBackground() != SGRPlayerBackgroundAnimated) return;
    static SGRPlayerMotionWatcher *watcher;
    watcher = [SGRPlayerMotionWatcher new];
    SGAddPlayerStateObserver(watcher);
}
