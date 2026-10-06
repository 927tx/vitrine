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
#import "Redesigned/Navbar/Navbar.h"

static const CGFloat kCardRadius = 24;
// The strip's pane is this much smaller than the strip at each end, so a gap parts it from the card's glass.
static const CGFloat kStripInset = 4;
static char kGlassKey, kStripGlassKey;
static __weak UIView *sg_card;
static CGRect sg_stripFrame;
static __weak UIVisualEffectView *sg_cardGlass;
static __weak UIView *sg_cardArtwork;
static __weak UIView *sg_progress;
static __weak UIViewController *sg_container;
// The container's view while it stands in the minimized tab bar's row, below the page that holds it.
static __weak UIView *sg_inline;

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
    __block UIView *progress = sg_progress;
    if (![progress isDescendantOfView:card]) {
        progress = nil;
        SGForEachView(card, ^(UIView *v) {
            CGRect f = v.frame;
            if (!progress && !inStrip(v, card) && f.size.height <= 3 && f.size.width >= 200 && v.superview.bounds.size.height >= 40) progress = v;
        });
        sg_progress = progress;
    }
    // Under the text, 226pt on a full width card, shorter on the one in the minimized tab bar.
    CGRect target = CGRectMake(52, card.bounds.size.height - 6, MAX(0, card.bounds.size.width - 160), 2);
    if (progress && !CGRectEqualToRect(progress.frame, target)) {
        progress.frame = target;
        [progress setNeedsLayout];
        [progress layoutIfNeeded];
    }
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

// The bar's left and right edges in its superview, set through the constants of the constraints that hold
// them there (their constants as Spotify set them kept to go back to), or through its frame when it is laid
// out by frame. A frame alone does not move a view laid out by constraints, nor what is constrained inside
// it (harness/tabbar). NO, with nothing changed, when its edges are held some other way, or right to left.
static NSMapTable<NSLayoutConstraint *, NSNumber *> *sg_constants;
static CGRect sg_fullFrame, sg_narrowFrame;

static void restoreEdges(UIView *bar) {
    for (NSLayoutConstraint *constraint in sg_constants) constraint.constant = [[sg_constants objectForKey:constraint] doubleValue];
    [sg_constants removeAllObjects];
    if (bar.translatesAutoresizingMaskIntoConstraints && CGRectEqualToRect(bar.frame, sg_narrowFrame)) bar.frame = sg_fullFrame;
    sg_narrowFrame = CGRectNull;
}

static BOOL setEdges(UIView *bar, CGFloat left, CGFloat right) {
    UIView *superview = bar.superview;
    if (bar.translatesAutoresizingMaskIntoConstraints) {
        CGRect frame = CGRectMake(left, bar.frame.origin.y, right - left, bar.frame.size.height);
        if (!CGRectEqualToRect(bar.frame, sg_narrowFrame)) sg_fullFrame = bar.frame;
        sg_narrowFrame = frame;
        if (!CGRectEqualToRect(bar.frame, frame)) bar.frame = frame;
        return YES;
    }
    if (superview.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft) return NO;
    if (!sg_constants) sg_constants = [NSMapTable weakToStrongObjectsMapTable];
    NSUInteger held = 0;
    for (NSLayoutConstraint *constraint in superview.constraints) {
        NSLayoutAttribute attribute = constraint.firstAttribute;
        BOOL barFirst = constraint.firstItem == bar && constraint.secondItem == superview;
        if (!constraint.active || constraint.relation != NSLayoutRelationEqual || constraint.multiplier != 1 || attribute != constraint.secondAttribute
            || (!barFirst && !(constraint.secondItem == bar && constraint.firstItem == superview))) continue;
        BOOL isLeft = attribute == NSLayoutAttributeLeading || attribute == NSLayoutAttributeLeft;
        if (!isLeft && attribute != NSLayoutAttributeTrailing && attribute != NSLayoutAttributeRight) continue;
        if (![sg_constants objectForKey:constraint]) [sg_constants setObject:@(constraint.constant) forKey:constraint];
        CGFloat edge = isLeft ? 0 : superview.bounds.size.width, value = isLeft ? left : right;
        CGFloat constant = barFirst ? value - edge : edge - value;
        if (constraint.constant != constant) constraint.constant = constant;
        held |= isLeft ? 1 : 2;
    }
    if (held == 3) return YES;
    restoreEdges(bar);
    static dispatch_once_t once;
    dispatch_once(&once, ^{ SGLog(@"now playing bar: its edges are not held by its superview's constraints, so it stays above the tab bar"); });
    return NO;
}

// In the row the card keeps the cover, the title and play, as the Music app's does: the device and add
// buttons stand aside while it is there and come back with the full card. Only what this hid is shown again.
static NSHashTable<UIView *> *sg_tucked;

static void tuckExtras(UIView *bar, BOOL tuck) {
    if (!sg_tucked) sg_tucked = [NSHashTable weakObjectsHashTable];
    if (!tuck) {
        for (UIView *item in sg_tucked) item.hidden = NO;
        [sg_tucked removeAllObjects];
        return;
    }
    SGForEachView(bar, ^(UIView *v) {
        NSString *name = v.accessibilityIdentifier;
        if (![name isEqualToString:@"Components.ConnectButtonOutputSwitcher"] && ![name isEqualToString:@"Components.UI.AddToButton"]) return;
        // The stack's own item, so the stack closes the gap.
        UIView *item = v;
        while (item.superview && item.superview != bar && ![item.superview isKindOfClass:UIStackView.class]) item = item.superview;
        if (![item.superview isKindOfClass:UIStackView.class] || item.hidden) return;
        item.hidden = YES;
        [sg_tucked addObject:item];
    });
}

// In the minimized tab bar's row (TabBar.x): the bar narrowed to the slot by its edges, so Spotify's content
// lays itself out to the width, and moved down by a transform on the container's view, which Spotify's
// layout leaves alone. Outside a Jam only: its strip has no room in the row.
static void placeInline(UIViewController *container) {
    UIView *view = container.view;
    UIView *bar = container.childViewControllers.firstObject.viewIfLoaded;
    UIView *strip = bar ? stripIn(bar) : nil;
    BOOL jam = strip && !strip.hidden && strip.alpha >= 0.01 && strip.window && strip.bounds.size.height >= 1;
    CGRect slot = !bar || bar.superview != view || jam ? CGRectNull : SGRTabBarInlineSlot(view.superview, bar.bounds.size.height);
    // Where the view stands untransformed, in the slot's coordinates.
    CGPoint origin = CGPointMake(view.center.x - view.bounds.size.width / 2, view.center.y - view.bounds.size.height / 2);
    if (CGRectIsNull(slot) || !setEdges(bar, CGRectGetMinX(slot) - origin.x, CGRectGetMaxX(slot) - origin.x)) {
        if (sg_inline) restoreEdges(bar);
        if (sg_inline) tuckExtras(bar, NO);
        sg_inline = nil;
        if (!CGAffineTransformIsIdentity(view.transform)) view.transform = CGAffineTransformIdentity;
        return;
    }
    CGAffineTransform move = CGAffineTransformMakeTranslation(0, CGRectGetMidY(slot) - origin.y - CGRectGetMidY(bar.frame));
    if (!CGAffineTransformEqualToTransform(view.transform, move)) view.transform = move;
    tuckExtras(bar, YES);
    sg_inline = view;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableString *clips = [NSMutableString string];
        for (UIView *v = view.superview; v; v = v.superview) if (v.clipsToBounds) [clips appendFormat:@" %@", v.class];
        SGLog(@"now playing bar in the tab bar's row at %@, clipped by:%@", NSStringFromCGRect(slot), clips.length ? clips : @" nothing");
    });
}

void SGRNowPlayingBarFollowTabBar(void) {
    UIViewController *container = sg_container;
    if (!container.isViewLoaded) return;
    placeInline(container);
    [container.view setNeedsLayout];
    [container.view layoutIfNeeded];
}

static void styleNowPlayingBar(UIViewController *container) {
    UIViewController *barVC = container.childViewControllers.firstObject;
    UIView *bar = barVC.viewIfLoaded ?: container.view;
    sg_container = container;
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
    placeInline(container);

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

// The page the bar stands in passes touches outside the bar through, and the bar in the tab bar's row is
// below the page's bounds: a touch there reaches the bar only through this.
%hook _TtC22NowPlaying_BarPageImplP33_CCC0D2EEA6D4725EECD8965E8C38C86D20TouchPassthroughView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = %orig;
    UIView *moved = sg_inline;
    if ((hit && hit != (UIView *)self) || ![moved isDescendantOfView:(UIView *)self]) return hit;
    CGPoint inMoved = [(UIView *)self convertPoint:point toView:moved];
    return [moved pointInside:inMoved withEvent:event] ? ([moved hitTest:inMoved withEvent:event] ?: hit) : hit;
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
        @"_TtC22NowPlaying_BarPageImplP33_CCC0D2EEA6D4725EECD8965E8C38C86D20TouchPassthroughView",
    ]);
}
