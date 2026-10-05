#import <CoreImage/CoreImage.h>
#import "Core/SGCore.h"
#import "SGRFluid.h"
#import "SGRTokens.h"

// Each copy: its side as a share of the visible rect's longer side, its centre as shares of that rect, and
// one turn's length in seconds (negative turns the other way).
static const struct { CGFloat side, x, y; CFTimeInterval turn; } kCopy[] = {
    {2.2, 0.25, 0.20, 46},
    {2.0, 0.80, 0.35, -61},
    {2.4, 0.30, 0.75, 73},
    {1.8, 0.70, 0.85, -54},
};
enum { kCopies = sizeof(kCopy) / sizeof(kCopy[0]) };
// The blurred cover is small: it is drawn several times the screen's size, so detail is lost anyway.
static const CGFloat kBlurSide = 128, kBlurRadius = 10, kSaturation = 1.5, kBrightness = -0.08;
// The shade over the bottom of the visible rect, where the controls are.
static const CGFloat kShadeFrom = 0.45, kShadeAlpha = 0.55;

static UIImage *blurred(UIImage *image) {
    CGImageRef source = image.CGImage;
    if (!source) return nil;
    CIImage *input = [CIImage imageWithCGImage:source];
    CGFloat scale = kBlurSide / MAX(input.extent.size.width, input.extent.size.height);
    input = [input imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    CGRect extent = input.extent;
    CIImage *output = [[[input imageByClampingToExtent]
        imageByApplyingFilter:@"CIGaussianBlur" withInputParameters:@{kCIInputRadiusKey: @(kBlurRadius)}]
        imageByApplyingFilter:@"CIColorControls" withInputParameters:@{kCIInputSaturationKey: @(kSaturation), kCIInputBrightnessKey: @(kBrightness)}];
    static CIContext *context;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ context = [CIContext contextWithOptions:nil]; });
    CGImageRef cg = [context createCGImage:[output imageByCroppingToRect:extent] fromRect:extent];
    if (!cg) return nil;
    UIImage *result = [UIImage imageWithCGImage:cg];
    CGImageRelease(cg);
    return result;
}

@implementation SGRFluidLayer {
    CALayer *_copies[kCopies];
    CAGradientLayer *_shade;
    UIImage *_source;
    NSUInteger _generation;
    BOOL _moving;
    CFTimeInterval _since, _elapsed;
    CGRect _laidOutFor;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    self.masksToBounds = YES;
    self.backgroundColor = UIColor.blackColor.CGColor;
    for (int i = 0; i < kCopies; i++) {
        _copies[i] = [CALayer layer];
        _copies[i].contentsGravity = kCAGravityResizeAspectFill;
        _copies[i].opacity = i == 0 ? 1 : 0.7;
        [self addSublayer:_copies[i]];
    }
    _shade = [CAGradientLayer layer];
    _shade.colors = @[(id)[UIColor colorWithWhite:0 alpha:0].CGColor, (id)[UIColor colorWithWhite:0 alpha:kShadeAlpha].CGColor];
    [self addSublayer:_shade];
    return self;
}

- (BOOL)moving {
    return _moving;
}

- (void)setVisibleRect:(CGRect)rect {
    if (CGRectEqualToRect(rect, _visibleRect)) return;
    _visibleRect = rect;
    [self setNeedsLayout];
}

- (void)layoutSublayers {
    [super layoutSublayers];
    CGRect bounds = self.bounds;
    CGRect visible = CGRectIsEmpty(_visibleRect) ? bounds : _visibleRect;
    CGFloat total = MAX(1, bounds.size.height);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _shade.frame = bounds;
    _shade.locations = @[@(MIN(1, (CGRectGetMinY(visible) + visible.size.height * kShadeFrom) / total)),
                         @(MIN(1, CGRectGetMaxY(visible) / total))];
    if (!CGRectEqualToRect(visible, _laidOutFor) && visible.size.width >= 1) {
        _laidOutFor = visible;
        BOOL moving = _moving;
        if (moving) [self stop];
        CGFloat longer = MAX(visible.size.width, visible.size.height);
        for (int i = 0; i < kCopies; i++) {
            CGFloat side = round(longer * kCopy[i].side);
            _copies[i].bounds = CGRectMake(0, 0, side, side);
            _copies[i].position = CGPointMake(CGRectGetMinX(visible) + visible.size.width * kCopy[i].x,
                                              CGRectGetMinY(visible) + visible.size.height * kCopy[i].y);
        }
        if (moving) [self start];
    }
    [CATransaction commit];
}

- (void)setArtwork:(UIImage *)image animated:(BOOL)animated {
    if (!image || image == _source) return;
    _source = image;
    NSUInteger generation = ++_generation;
    __weak SGRFluidLayer *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        UIImage *blur = blurred(image);
        dispatch_async(dispatch_get_main_queue(), ^{
            SGRFluidLayer *layer = weakSelf;
            if (!blur || !layer || generation != layer->_generation) return;
            [layer show:blur animated:animated];
        });
    });
}

- (void)show:(UIImage *)blur animated:(BOOL)animated {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (int i = 0; i < kCopies; i++) {
        if (animated) {
            CATransition *fade = [CATransition animation];
            fade.type = kCATransitionFade;
            fade.duration = SGRCrossfade;
            [_copies[i] addAnimation:fade forKey:@"contents"];
        }
        _copies[i].contents = (__bridge id)blur.CGImage;
    }
    [CATransaction commit];
}

#pragma mark - moving

- (void)setMoving:(BOOL)moving {
    if (moving == _moving) return;
    _moving = moving;
    if (moving) [self start];
    else [self stop];
}

- (void)start {
    if (self.bounds.size.width < 1) return;
    _since = CACurrentMediaTime();
    CAFrameRateRange rate = CAFrameRateRangeMake(15, 60, 30);
    for (int i = 0; i < kCopies; i++) {
        CFTimeInterval length = fabs(kCopy[i].turn);
        // The turn's offset carries the angle it stopped at, so the resting angle goes back to none.
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        _copies[i].transform = CATransform3DIdentity;
        [CATransaction commit];
        CABasicAnimation *turn = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        turn.byValue = @(kCopy[i].turn > 0 ? 2 * M_PI : -2 * M_PI);
        turn.duration = length;
        turn.repeatCount = HUGE_VALF;
        turn.additive = YES;
        turn.timeOffset = fmod(_elapsed, length);
        turn.preferredFrameRateRange = rate;
        [_copies[i] addAnimation:turn forKey:@"turn"];
    }
}

// Every copy held at the angle it is drawn at now.
- (void)stop {
    if (_since > 0) _elapsed += CACurrentMediaTime() - _since;
    _since = 0;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (int i = 0; i < kCopies; i++) {
        CFTimeInterval length = fabs(kCopy[i].turn);
        CGFloat angle = (kCopy[i].turn > 0 ? 1 : -1) * 2 * M_PI * fmod(_elapsed, length) / length;
        [_copies[i] removeAnimationForKey:@"turn"];
        _copies[i].transform = CATransform3DMakeRotation(angle, 0, 0, 1);
    }
    [CATransaction commit];
}

@end
