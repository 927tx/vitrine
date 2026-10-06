// The redesign's now playing bar: the album-coloured card becomes a glass card with round artwork and the
// progress line under the text. Spotify's own labels, buttons and gestures stay in place.
//
// The full screen player morphs the bar's own card and artwork into the cover art. The bar was
// written to hand itself back to Spotify for that animation, from NowPlaying_ViewPageImpl's
// Show/CloseFullscreenAnimatedTransitioning, but Spotify 9.1.78 never runs the player through those,
// so the handback never happened and is gone; if the morph ever reads as a cut, the place to start is
// Shared/Player/PlayerEvents.h, which does fire. What does move with the player is a stand-in of the
// bar, which BarTransition.x keeps glass behind.
//
// Tree (trees/home.txt): NowPlayingBarContainerViewController.view 402x56 > NowPlayingBarViewController.view
//   at {8,0} 386x56 > UIView 386x56 (the painted card) > artwork 40x40 r=4, title stack,
//   progress line 370x2 at the bottom. The glass pane goes on the container's view.
//
// In a Jam Spotify puts a "Jam by ..." strip on the bar, a SwiftUI _UIHostingView of
// Jam_AttachmentsImpl.JamHatElement as wide as the card and 44pt high, and grows the bar by its height
// (386x100, the track card at y = 44). It paints the strip, or a view around the strip and the track, as
// well, so the card is the painted view that holds the track and has no strip in it. The strip stays out
// of the card's glass and gets a pane of its own above it, since its own paint goes clear with the rest.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRRepaint.h"
#import "Redesigned/Kit/SGRGlass.h"
#import "Redesigned/Kit/SGRTokens.h"
#import "NowPlayingBar.h"

static const CGFloat kCardRadius = 24;
// The strip's pane is this much smaller than the strip at each end, so a gap parts it from the card's glass.
static const CGFloat kStripInset = 4;
static char kGlassKey, kStripGlassKey;
static __weak UIView *sg_card;
static CGRect sg_stripFrame;
static __weak UIVisualEffectView *sg_cardGlass;
static __weak UIView *sg_cardArtwork;

CGRect SGRNowPlayingCardFrameIn(UIView *host, CGFloat *radius) {
    UIVisualEffectView *glass = sg_cardGlass;
    if (!glass.superview || !glass.window || !host) return CGRectNull;
    if (radius) *radius = MIN(kCardRadius, glass.bounds.size.height / 2);
    return [host convertRect:glass.bounds fromView:glass];
}

CGRect SGRNowPlayingArtworkFrameIn(UIView *host) {
    UIView *artwork = sg_cardArtwork;
    if (!artwork.window || !host) return CGRectNull;
    return [host convertRect:artwork.bounds fromView:artwork];
}

// The Jam strip. The height keeps out a view of the same module that can hold the track card too.
static BOOL isStrip(UIView *view) {
    NSString *name = NSStringFromClass(view.class);
    return view.bounds.size.height <= 60 && [name containsString:@"AttachmentsImpl"] && [name containsString:@"Hat"];
}

static BOOL inStrip(UIView *view, UIView *root) {
    for (UIView *v = view; v && v != root; v = v.superview) if (isStrip(v)) return YES;
    return NO;
}

static UIView *stripIn(UIView *root) {
    __block UIView *strip = nil;
    SGForEachView(root, ^(UIView *v) { if (!strip && isStrip(v)) strip = v; });
    return strip;
}

// What holds the track on the bar: the title and artist block, else the artwork (a 36 to 48pt square that
// is not a button), never anything in the strip. Nil when neither is there.
static UIView *trackMarker(UIView *bar) {
    __block UIView *info = nil, *artwork = nil;
    SGForEachView(bar, ^(UIView *v) {
        if (info || inStrip(v, bar)) return;
        if ([NSStringFromClass(v.class) containsString:@"InformationContainer"]) info = v;
        CGSize size = v.bounds.size;
        BOOL square = size.width >= 36 && size.width <= 48 && fabs(size.width - size.height) < 1;
        if (!artwork && square && ![v isKindOfClass:UIControl.class]) artwork = v;
    });
    return info ?: artwork;
}

// A card holds the track and has no strip in it; one with the strip in it only when there is no other.
// Among equals the largest, which outside a Jam is the card it always was.
static BOOL isGoodCard(UIView *card, UIView *bar, UIView *marker) {
    return SGIsInside(card, bar) && !inStrip(card, bar) && (!marker || [marker isDescendantOfView:card]);
}

static UIView *chooseCard(UIView *bar, UIView *marker) {
    UIView *best = nil;
    BOOL bestHasStrip = NO;
    CGFloat bestArea = 0;
    for (UIView *v in sgr_nowPlayingPainted) {
        // Card sized: the paint itself has gone clear by now.
        if (!SGLooksLikeCard(v, UIColor.whiteColor.CGColor) || !isGoodCard(v, bar, marker)) continue;
        BOOL hasStrip = stripIn(v) != nil;
        CGFloat area = v.bounds.size.width * v.bounds.size.height;
        BOOL better = !best || (hasStrip != bestHasStrip ? !hasStrip : area > bestArea);
        if (!better) continue;
        best = v;
        bestHasStrip = hasStrip;
        bestArea = area;
    }
    return best;
}

// Fallback when nothing is painted: the box around artwork, text and the small buttons.
static CGRect contentBounds(UIView *bar, UIView *target) {
    __block CGRect box = CGRectNull;
    SGForEachView(bar, ^(UIView *v) {
        if (v.hidden || v.alpha == 0 || inStrip(v, bar)) return;
        CGFloat width = v.bounds.size.width;
        BOOL content = ([v isKindOfClass:UIImageView.class] && width >= 20 && width <= 120)
            || [v isKindOfClass:UILabel.class]
            || ([v isKindOfClass:UIControl.class] && width <= 100);
        if (content) box = CGRectUnion(box, SGFrameIn(v, target));
    });
    return CGRectIsNull(box) ? box : CGRectInset(box, -10, -8);
}

static void roundView(UIView *view, CGFloat radius) {
    view.layer.cornerRadius = radius;
    view.layer.cornerCurve = kCACornerCurveContinuous;
}

static void restyleCardContent(UIView *card) {
    SGForEachView(card, ^(UIView *v) {
        if (inStrip(v, card)) return;
        CGSize size = v.bounds.size;
        BOOL square = size.width >= 36 && size.width <= 48 && fabs(size.width - size.height) < 1;
        if (!square || v.layer.cornerRadius <= 0) return;
        if (v.layer.cornerRadius >= size.width / 2) {
            if (!sg_cardArtwork) sg_cardArtwork = v;
            return;
        }
        UIView *outer = v;
        for (UIView *u = v; u && u != card && CGSizeEqualToSize(u.bounds.size, size); u = u.superview) {
            roundView(u, size.width / 2);
            u.clipsToBounds = YES;
            outer = u;
        }
        sg_cardArtwork = outer;
    });
    SGForEachView(card, ^(UIView *v) {
        CGRect f = v.frame;
        if (inStrip(v, card) || f.size.height > 3 || f.size.width < 200 || v.superview.bounds.size.height < 40) return;
        CGRect target = CGRectMake(52, card.bounds.size.height - 6, 226, 2);
        if (CGRectEqualToRect(f, target)) return;
        v.frame = target;
        [v setNeedsLayout];
        [v layoutIfNeeded];
    });
}

// The strip's own pane, a strip high less the gaps, on the card's side the strip is on. It is measured from
// the card's settled frame and the strip's height, not from the strip's frame: Spotify animates the strip
// in, and a pane taken from it mid-way sat about 12pt off and cut its ⋯ button. The glass comes in and goes
// by its effect, never by alpha (SGRGlass.h).
static void placeStripGlass(UIView *host, UIView *strip, CGRect card, BOOL above) {
    UIVisualEffectView *pane = objc_getAssociatedObject(host, &kStripGlassKey);
    if (!strip) {
        if (pane.effect) SGRAnimate(SGRMotionExit, ^{ SGRShowGlass(pane, NO); }, nil);
        return;
    }
    BOOL made = pane != nil;
    pane = SGGlassFor(host, &kStripGlassKey);
    if (!made) {
        pane.effect = nil;
        pane.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    }
    CGFloat height = strip.bounds.size.height;
    CGRect frame = CGRectMake(card.origin.x, above ? CGRectGetMinY(card) - height : CGRectGetMaxY(card), card.size.width, height);
    pane.frame = CGRectInset(frame, 0, kStripInset);
    SGShapeGlass(pane, MIN(kCardRadius, pane.bounds.size.height / 2), NO);
    if (!pane.effect) SGRAnimate(SGRMotionRespond, ^{ SGRShowGlass(pane, YES); }, nil);
}

static void styleNowPlayingBar(UIViewController *container) {
    UIViewController *barVC = container.childViewControllers.firstObject;
    UIView *bar = barVC.viewIfLoaded ?: container.view;
    if (!sgr_nowPlayingPainted) sgr_nowPlayingPainted = [NSHashTable weakObjectsHashTable];
    sgr_nowPlayingRoot = bar;

    // What is painted now, before it goes clear; SGRRepaint.x adds what Spotify paints later. Its size is
    // judged when the card is chosen: in a Jam the card can still be unsized here (harness/tabbar).
    SGForEachView(bar, ^(UIView *v) {
        if (![v isKindOfClass:UIVisualEffectView.class] && !SGKeepsColor(v) && SGIsVisibleColor(v.layer.backgroundColor)) [sgr_nowPlayingPainted addObject:v];
    });
    // The card stays while it still holds the track with no strip in it, whatever Spotify paints after.
    UIView *marker = trackMarker(bar);
    UIView *card = sg_card;
    if (!card || !isGoodCard(card, bar, marker) || stripIn(card)) card = sg_card = chooseCard(bar, marker);

    container.view.layer.backgroundColor = NULL;
    SGStripBackgrounds(bar);

    UIView *strip = stripIn(bar);
    if (strip && (strip.hidden || strip.alpha < 0.01 || !strip.window)) strip = nil;
    // Spotify lays the strip out after the bar and moves it in, so the bar is styled again a moment after
    // the strip has moved, until it stays put.
    CGRect stripFrame = strip ? SGFrameIn(strip, container.view) : CGRectZero;
    if (!CGRectEqualToRect(stripFrame, sg_stripFrame)) {
        sg_stripFrame = stripFrame;
        UIView *host = container.view;
        dispatch_async(dispatch_get_main_queue(), ^{ [host setNeedsLayout]; });
    }
    if (strip.bounds.size.height < 1) strip = nil;

    CGRect frame = card ? SGFrameIn(card, container.view) : contentBounds(bar, container.view);
    if (CGRectIsNull(frame)) return;
    // The strip comes out of the card's glass from its side: all of it when the card is a view around both,
    // else as much as overlaps.
    BOOL stripAbove = NO;
    if (strip) {
        stripAbove = CGRectGetMidY(stripFrame) < CGRectGetMidY(frame);
        CGFloat cut = card && [strip isDescendantOfView:card] ? strip.bounds.size.height : CGRectIntersection(frame, stripFrame).size.height;
        frame.size.height -= cut;
        if (stripAbove) frame.origin.y += cut;
    }
    frame.size.height = MIN(frame.size.height, 80);
    if (frame.size.height < 30 || frame.size.width < 100) return;

    CGFloat radius = MIN(kCardRadius, frame.size.height / 2);
    if (card) {
        roundView(card, radius);
        restyleCardContent(card);
    }

    UIVisualEffectView *glass = SGGlassFor(container.view, &kGlassKey);
    // Dark whatever the system is set to: the bar is outside the navigation stacks Spotify makes dark, and
    // took the system's light glass on a phone in light mode (TabBar.x).
    if (glass.overrideUserInterfaceStyle != UIUserInterfaceStyleDark) glass.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    sg_cardGlass = glass;
    glass.frame = frame;
    SGShapeGlass(glass, radius, NO);
    placeStripGlass(container.view, strip, frame, stripAbove);

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        SGLog(@"now playing card %@ at %@ (bar %@, container %@)", card.class, NSStringFromCGRect(frame),
              NSStringFromCGRect(bar.frame), NSStringFromCGRect(container.view.bounds));
    });
    static dispatch_once_t jamOnce;
    if (strip) dispatch_once(&jamOnce, ^{
        SGLog(@"now playing card in a Jam: %@ at %@, strip %@ at %@ (bar %@)", card.class, NSStringFromCGRect(frame), strip.class,
              NSStringFromCGRect(SGFrameIn(strip, container.view)), NSStringFromCGRect(bar.frame));
    });
}

%hook _TtC18NowPlaying_BarImpl36NowPlayingBarContainerViewController
- (void)viewDidLayoutSubviews {
    %orig;
    styleNowPlayingBar((UIViewController *)self);
}
%end

%hook _TtC18NowPlaying_BarImpl27NowPlayingBarViewController
- (void)viewDidLayoutSubviews {
    %orig;
    UIViewController *parent = ((UIViewController *)self).parentViewController;
    if ([NSStringFromClass(parent.class) containsString:@"NowPlayingBarContainer"]) styleNowPlayingBar(parent);
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    SGRequireClasses(@[
        @"_TtC18NowPlaying_BarImpl36NowPlayingBarContainerViewController",
        @"_TtC18NowPlaying_BarImpl27NowPlayingBarViewController",
    ]);
}
