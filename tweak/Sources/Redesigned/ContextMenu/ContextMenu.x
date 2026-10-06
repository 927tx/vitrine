// The redesign's ⋯ as the system menu (ContextMenu.h says what and why).
//
// The sheet is ContextMenu_InternalImpl.ContextMenuViewController, presented on its own or as the root of
// ContextMenuNativeNavigationController; its rows are a table sized to its content (Shared/Player/
// SpeedPitchMenu.x and harness/menu say more), each a ContextMenuTableViewCell whose only ivar is the
// containedView Spotify draws the row in (nm on 9.1.78). So a row is read off the cell it fills -- its words
// from its labels, its glyph from its image view or else drawn off the small view at its leading edge -- and
// picked through the table's own delegate, as a tap on it would be.
//
// What UIKit does was checked in the simulator against harness/system-menu/ (iOS 27): a presentation's
// container exists from the presented controller's viewWillAppear: on, not when presentViewController: returns,
// so that is where the sheet is hidden; a menu asked for while the sheet's presentation is still under way
// never comes up, so it is asked for from the presentation's completion, and the sheet goes up unanimated for
// that to be at once; -performPrimaryAction brings the menu up over the hidden sheet and calls
// willDisplayMenuForConfiguration: before it returns; a pick runs the action's handler before
// willEndForConfiguration:, so by the end of the menu's dismissal it is known whether there was one; a deferred
// element in a submenu is asked for its items when that submenu opens, not with the menu, so More's rows are
// not kept from one menu to the next: by the time More is opened the sheet has nearly always read them.
#import <objc/message.h>
#import <objc/runtime.h>
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Shared/Player/SpeedPitch.h"
#import "ContextMenu.h"

// A sheet this soon after a touch on a watched ⋯ is that ⋯'s menu, as SGRPinnedMoreWindow has it for pages.
static const NSTimeInterval kClaimWindow = 3;
// After a pick of Spotify's, how long its sheet has to start going before it is taken to have opened a page
// of its own and is shown.
static const NSTimeInterval kSettle = 0.5;
// How often the sheet is asked for its rows until it has them.
static const NSTimeInterval kRowsPoll = 0.1;
// How long the menu's dismissal may take before it is taken to be over without having said so.
static const NSTimeInterval kEndedLimit = 3;
// How long a quick item picked before the sheet has its rows waits for them before the sheet is shown.
static const NSTimeInterval kQuickWait = 2;

static NSString *const kSheetClass = @"_TtC24ContextMenu_InternalImpl25ContextMenuViewController";
static NSString *const kTopMenu = @"com.vitrine.systemmenu.top";
static NSString *const kQuickMenu = @"com.vitrine.systemmenu.quick";

static char kAnchorKey, kItemsKey, kKindKey, kWatchedKey, kSessionKey;

static __weak UIView *sg_claimButton;
static NSTimeInterval sg_claimAt;

// The player's quick items: what the item says, its symbol, and the title of Spotify's row it fires, compared
// without case. Spotify's rows carry no identifier known to be stable (the first read logs what they have), so
// the title is what is matched; a sheet in another language matches none, and the row is left out.
static NSArray<NSArray<NSString *> *> *quickItems(void) {
    return @[@[@"Share", @"square.and.arrow.up", @"share"],
             @[@"Add to Playlist", @"text.badge.plus", @"add to playlist"],
             @[@"Add to Queue", @"text.line.last.and.arrowtriangle.forward", @"add to queue"]];
}

// Which quick items (their rows' titles) the last sheet of each kind had.
static NSMutableDictionary<NSString *, NSArray<NSString *> *> *sg_quickSeen;

#pragma mark - the sheet

// Spotify's ContextMenuViewController in what was presented: itself, or the root of its navigation controller.
static UIViewController *sheetIn(UIViewController *presented) {
    if ([NSStringFromClass(presented.class) isEqualToString:kSheetClass]) return presented;
    if ([presented isKindOfClass:UINavigationController.class]) {
        UIViewController *root = ((UINavigationController *)presented).viewControllers.firstObject;
        if ([NSStringFromClass(root.class) isEqualToString:kSheetClass]) return root;
    }
    return nil;
}

static UITableView *tableIn(UIView *root, int depth) {
    if ([root isKindOfClass:UITableView.class]) return (UITableView *)root;
    if (!root || depth > 5) return nil;
    for (UIView *child in root.subviews) {
        UITableView *table = tableIn(child, depth + 1);
        if (table) return table;
    }
    return nil;
}

static NSInteger rowCount(UITableView *table) {
    NSInteger rows = 0;
    for (NSInteger section = 0; section < table.numberOfSections; section++) rows += [table numberOfRowsInSection:section];
    return rows;
}

static BOOL shows(UIView *view) {
    return !view.hidden && view.alpha > 0.01;
}

// The visible labels' words in reading order: the row's title first, a line under it second.
static NSArray<UILabel *> *labelsIn(UIView *root) {
    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    SGForEachView(root, ^(UIView *view) {
        if ([view isKindOfClass:UILabel.class] && shows(view) && ((UILabel *)view).text.length) [labels addObject:(UILabel *)view];
    });
    [labels sortUsingComparator:^NSComparisonResult(UILabel *a, UILabel *b) {
        CGRect ra = [a convertRect:a.bounds toView:root], rb = [b convertRect:b.bounds toView:root];
        if (fabs(CGRectGetMinY(ra) - CGRectGetMinY(rb)) > 4) return CGRectGetMinY(ra) < CGRectGetMinY(rb) ? NSOrderedAscending : NSOrderedDescending;
        return CGRectGetMinX(ra) < CGRectGetMinX(rb) ? NSOrderedAscending : NSOrderedDescending;
    }];
    return labels;
}

// The first accessibility identifier in the row, for the log.
static NSString *identifierIn(UIView *root) {
    __block NSString *found = nil;
    SGForEachView(root, ^(UIView *view) {
        if (!found && view.accessibilityIdentifier.length) found = view.accessibilityIdentifier;
    });
    return found;
}

// The row's glyph as a template, for the menu to draw in its own colour: an image view's picture, else the
// small view at the row's leading edge drawn into one (Encore draws its icons into a view of its own,
// Redesigned/Playlist/PlaylistMenu.x).
static UIImage *glyphIn(UIView *root) {
    __block UIImageView *image = nil;
    __block UIView *drawn = nil;
    __block CGFloat drawnX = CGFLOAT_MAX;
    SGForEachView(root, ^(UIView *view) {
        if (view == root || !shows(view)) return;
        CGSize size = view.bounds.size;
        if (size.width < 12 || size.width > 40 || size.height < 12 || size.height > 40) return;
        if (!image && [view isKindOfClass:UIImageView.class] && ((UIImageView *)view).image) image = (UIImageView *)view;
        CGFloat x = [view convertRect:view.bounds toView:root].origin.x;
        if (![view isKindOfClass:UILabel.class] && !view.subviews.count && x < drawnX) {
            drawn = view;
            drawnX = x;
        }
    });
    if (image) return [image.image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    if (!drawn || drawnX > root.bounds.size.width / 3) return nil;
    UIImage *picture = [[[UIGraphicsImageRenderer alloc] initWithSize:drawn.bounds.size] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [drawn.layer renderInContext:context.CGContext];
    }];
    return [picture imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

// Spotify greys a row out (lyrics for a track no source has them for) rather than leaving it out.
static BOOL rowEnabled(UITableView *table, NSIndexPath *path, UITableViewCell *cell, UILabel *title) {
    if (!cell.userInteractionEnabled) return NO;
    id<UITableViewDelegate> delegate = table.delegate;
    if ([delegate respondsToSelector:@selector(tableView:shouldHighlightRowAtIndexPath:)] && ![delegate tableView:table shouldHighlightRowAtIndexPath:path]) return NO;
    CGFloat alpha = 1;
    [title.textColor getRed:NULL green:NULL blue:NULL alpha:&alpha];
    return title.enabled && title.alpha * alpha >= 0.6;
}

// Picks the row as a tap would; a row that answers to no delegate is tapped through the first control in it.
static void selectRow(UITableView *table, NSIndexPath *path) {
    id<UITableViewDelegate> delegate = table.delegate;
    if ([delegate respondsToSelector:@selector(tableView:willSelectRowAtIndexPath:)]) path = [delegate tableView:table willSelectRowAtIndexPath:path];
    if (!path) return;
    if ([delegate respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) {
        [table selectRowAtIndexPath:path animated:NO scrollPosition:UITableViewScrollPositionNone];
        [delegate tableView:table didSelectRowAtIndexPath:path];
        return;
    }
    __block UIControl *control = nil;
    SGForEachView([table cellForRowAtIndexPath:path], ^(UIView *view) {
        if (!control && [view isKindOfClass:UIControl.class]) control = (UIControl *)view;
    });
    SGLog(@"system menu: the sheet's table has no didSelect, the row's %@ is tapped instead", control ? NSStringFromClass(control.class) : @"nothing");
    [control sendActionsForControlEvents:UIControlEventTouchUpInside];
}

// The mod's own rows in the table's header or footer view: the view itself or its children, controls of the
// mod's (SG…) with a label. Spotify's own header (the track it is for) is not one.
static NSArray<UIControl *> *modRowsIn(UIView *slot) {
    if (!slot || slot.bounds.size.height < 1) return @[];
    NSMutableArray<UIControl *> *rows = [NSMutableArray array];
    for (UIView *view in [slot isKindOfClass:UIControl.class] ? @[slot] : slot.subviews) {
        if ([view isKindOfClass:UIControl.class] && shows(view) && view.accessibilityLabel.length
            && [NSStringFromClass(view.class) hasPrefix:@"SG"]) [rows addObject:(UIControl *)view];
    }
    return rows;
}

static UIMenu *inlineGroup(NSArray<UIMenuElement *> *children) {
    return [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:children];
}

#pragma mark - one menu

// One row of the sheet as read: a row of Spotify's table (`path`) or a control of the mod's (`control`).
@interface SGRSheetRow : NSObject
@property (nonatomic, strong) NSIndexPath *path;
@property (nonatomic, weak) UIControl *control;
@property (nonatomic, copy) NSString *title, *subtitle, *identifier;
@property (nonatomic, strong) UIImage *image;
@property (nonatomic) BOOL enabled;
// The quick item this row is, by its row title in quickItems(); nil for none.
@property (nonatomic, copy) NSString *quick;
@end
@implementation SGRSheetRow
@end

@class SGRMenuAnchor;

// One ⋯ tap: the sheet Spotify presented, the anchor the menu comes from, and what was picked.
@interface SGRMenuSession : NSObject
@property (nonatomic, weak) UIViewController *presented;
@property (nonatomic, weak) SGRMenuAnchor *anchor;
@property (nonatomic, copy) SGRMenuItems items;
@property (nonatomic, copy) NSString *kind;
@property (nonatomic) BOOL displayed, revealed, ended, opened;
@property (nonatomic, copy) void (^pick)(void);
- (void)open;
- (void)reveal;
- (void)menuEnded;
@end

// An invisible button over the ⋯ that only hosts the menu. It takes touches only while the menu is up
// (UIKit will not present a menu from a view that takes none), so a tap on the ⋯ reaches the ⋯.
@interface SGRMenuAnchor : UIButton
@property (nonatomic, strong) SGRMenuSession *session;
@end

@implementation SGRMenuAnchor

- (void)contextMenuInteraction:(UIContextMenuInteraction *)interaction willDisplayMenuForConfiguration:(UIContextMenuConfiguration *)configuration
                      animator:(id<UIContextMenuInteractionAnimating>)animator {
    [super contextMenuInteraction:interaction willDisplayMenuForConfiguration:configuration animator:animator];
    self.session.displayed = YES;
}

- (void)contextMenuInteraction:(UIContextMenuInteraction *)interaction willEndForConfiguration:(UIContextMenuConfiguration *)configuration
                      animator:(id<UIContextMenuInteractionAnimating>)animator {
    [super contextMenuInteraction:interaction willEndForConfiguration:configuration animator:animator];
    SGRMenuSession *session = self.session;
    self.session = nil;
    self.userInteractionEnabled = NO;
    if (!animator) {
        [session menuEnded];
        return;
    }
    [animator addCompletion:^{ [session menuEnded]; }];
    // Should the dismissal never report its end, the hidden sheet is not left over the screen taking its touches.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kEndedLimit * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (session.ended) return;
        SGLog(@"system menu: the menu's dismissal did not end within %.0f s, the pick goes ahead", kEndedLimit);
        [session menuEnded];
    });
}

@end

@implementation SGRMenuSession {
    // The sheet's rows in its groups (the mod's header rows, each section, the mod's footer rows), nil until
    // the sheet has them; read once.
    NSArray<NSArray<SGRSheetRow *> *> *_groups;
    __weak UITableView *_table;
    // Run once the rows are read: More's items, a quick pick waiting for its row.
    NSMutableArray<dispatch_block_t> *_whenRead;
    // A quick pick is waiting for the rows, which keeps the poll going after the menu has gone.
    BOOL _waiting;
    // The quick row as the menu shows it, to know whether the rows changed it.
    NSString *_quickShown;
    NSTimer *_poll;
    CFTimeInterval _openedAt;
}

- (UIViewController *)sheet {
    return sheetIn(self.presented);
}

- (void)open {
    if (self.opened) return;
    self.opened = YES;
    SGRMenuAnchor *anchor = self.anchor;
    if (!anchor.window || !self.presented.presentingViewController) {
        SGLog(@"system menu: the ⋯ left the screen before its menu could open, Spotify's sheet shown");
        [self reveal];
        return;
    }
    _openedAt = CACurrentMediaTime();
    _whenRead = [NSMutableArray array];
    if (![self readRows]) [self pollRows];
    anchor.session = self;
    anchor.menu = [self menu];
    anchor.userInteractionEnabled = YES;
    SEL perform = NSSelectorFromString(@"performPrimaryAction");
    if ([anchor respondsToSelector:perform]) ((void (*)(id, SEL))objc_msgSend)(anchor, perform);
    if (!self.displayed) {
        UIContextMenuInteraction *interaction = anchor.contextMenuInteraction;
        for (id<UIInteraction> each in anchor.interactions) {
            if (!interaction && [(id)each isKindOfClass:UIContextMenuInteraction.class]) interaction = (UIContextMenuInteraction *)each;
        }
        SEL present = NSSelectorFromString(@"_presentMenuAtLocation:");
        if ([interaction respondsToSelector:present]) {
            CGPoint middle = CGPointMake(CGRectGetMidX(anchor.bounds), CGRectGetMidY(anchor.bounds));
            ((void (*)(id, SEL, CGPoint))objc_msgSend)(interaction, present, middle);
        }
    }
    // Both ways answer before they return; one more turn is given for an OS that answers a moment later.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.displayed || self.ended) return;
        SGLog(@"system menu: the menu did not come up, Spotify's sheet shown");
        anchor.userInteractionEnabled = NO;
        anchor.session = nil;
        [self reveal];
    });
}

#pragma mark the menu

// A page's ⋯: Spotify's rows, waited for. The player's: the quick row, the player's items and More, none of
// them waited for; More's rows are, when More is opened before the sheet has them.
- (UIMenu *)menu {
    if (!self.items) return [UIMenu menuWithChildren:@[[self deferredRows]]];
    NSMutableArray<UIMenuElement *> *children = [NSMutableArray array];
    UIMenu *quick = [self quickRow];
    if (quick) [children addObject:quick];
    NSArray<UIMenuElement *> *ours = self.items();
    if (ours.count) [children addObject:inlineGroup(ours)];
    UIMenu *more = [UIMenu menuWithTitle:@"More" image:[UIImage systemImageNamed:@"ellipsis.circle"] identifier:nil options:0 children:@[[self deferredRows]]];
    [children addObject:inlineGroup(@[more])];
    return [UIMenu menuWithTitle:@"" image:nil identifier:kTopMenu options:0 children:children];
}

// The sheet's rows as menu items, but for the quick ones. Uncached: every menu reads the sheet it was opened with.
- (UIDeferredMenuElement *)deferredRows {
    __weak SGRMenuSession *weakSelf = self;
    return [UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement *> *)) {
        SGRMenuSession *session = weakSelf;
        if (!session || session->_groups) {
            completion(session ? [session rowElements] : @[]);
            return;
        }
        SGLog(@"system menu: Spotify's rows asked for %.1f s after the menu opened, before the sheet has them", CACurrentMediaTime() - session->_openedAt);
        [session->_whenRead addObject:^{ completion([weakSelf rowElements] ?: @[]); }];
    }];
}

- (NSArray<UIMenuElement *> *)rowElements {
    NSMutableArray<UIMenuElement *> *groups = [NSMutableArray array];
    for (NSArray<SGRSheetRow *> *group in _groups) {
        NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];
        for (SGRSheetRow *row in group) {
            if (!row.quick) [actions addObject:[self actionFor:row]];
        }
        if (actions.count) [groups addObject:inlineGroup(actions)];
    }
    return groups;
}

- (UIAction *)actionFor:(SGRSheetRow *)row {
    __weak SGRMenuSession *weakSelf = self;
    UIAction *action = [UIAction actionWithTitle:row.title image:row.image identifier:nil handler:^(UIAction *picked) {
        weakSelf.pick = ^{ [weakSelf fire:row]; };
    }];
    action.subtitle = row.subtitle;
    if (!row.enabled) action.attributes = UIMenuElementAttributesDisabled;
    return action;
}

- (SGRSheetRow *)rowForQuick:(NSString *)quick {
    for (NSArray<SGRSheetRow *> *group in _groups) {
        for (SGRSheetRow *row in group) if ([row.quick isEqualToString:quick]) return row;
    }
    return nil;
}

// Share, Add to playlist and Add to queue as a row of three, those this sheet has: once it has its rows, the
// ones found in them; before, the ones the last sheet of this kind had, or all three.
- (UIMenu *)quickRow {
    NSArray<NSString *> *seen = sg_quickSeen[self.kind ?: @""];
    NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];
    NSMutableString *shown = [NSMutableString string];
    __weak SGRMenuSession *weakSelf = self;
    for (NSArray<NSString *> *item in quickItems()) {
        NSString *quick = item[2];
        SGRSheetRow *row = [self rowForQuick:quick];
        if (_groups ? !row : (seen && ![seen containsObject:quick])) continue;
        UIAction *action = [UIAction actionWithTitle:item[0] image:[UIImage systemImageNamed:item[1]] identifier:nil handler:^(UIAction *picked) {
            weakSelf.pick = ^{ [weakSelf fireQuick:quick]; };
        }];
        if (row && !row.enabled) action.attributes = UIMenuElementAttributesDisabled;
        [actions addObject:action];
        [shown appendFormat:@"%@%@; ", quick, row && !row.enabled ? @" (greyed out)" : @""];
    }
    _quickShown = shown;
    if (!actions.count) return nil;
    UIMenu *row = [UIMenu menuWithTitle:@"" image:nil identifier:kQuickMenu options:UIMenuOptionsDisplayInline children:actions];
    // Medium, a symbol over a short label: the HIG keeps small, symbols alone, for actions as closely related
    // as Bold and Italic, and gives medium to three important ones, which these are.
    row.preferredElementSize = UIMenuElementSizeMedium;
    return row;
}

// The rows came in while the menu is up: the quick row is put right if they changed it.
- (void)refreshQuickRow {
    if (!self.items || !self.displayed || self.ended) return;
    NSString *before = _quickShown;
    UIMenu *quick = [self quickRow];
    if ([before isEqualToString:_quickShown]) return;
    SGLog(@"system menu: the quick row is now %@(was %@)", _quickShown.length ? _quickShown : @"empty ", before.length ? before : @"empty");
    [self.anchor.contextMenuInteraction updateVisibleMenuWithBlock:^UIMenu *(UIMenu *visible) {
        // Only the top level, never a submenu that happens to be showing.
        if (![visible.identifier isEqualToString:kTopMenu]) return visible;
        NSMutableArray<UIMenuElement *> *children = [visible.children mutableCopy];
        NSUInteger at = [children indexOfObjectPassingTest:^BOOL(UIMenuElement *child, NSUInteger index, BOOL *stop) {
            return [child isKindOfClass:UIMenu.class] && [((UIMenu *)child).identifier isEqualToString:kQuickMenu];
        }];
        if (at != NSNotFound && quick) children[at] = quick;
        else if (at != NSNotFound) [children removeObjectAtIndex:at];
        else if (quick) [children insertObject:quick atIndex:0];
        return [visible menuByReplacingChildren:children];
    }];
}

#pragma mark the rows

- (void)pollRows {
    if (_poll) return;
    __weak SGRMenuSession *weakSelf = self;
    // In the common modes, so a scroll through the menu does not hold the rows back.
    _poll = [NSTimer timerWithTimeInterval:kRowsPoll repeats:YES block:^(NSTimer *timer) {
        SGRMenuSession *session = weakSelf;
        if (!session || (session.ended && !session->_waiting) || [session readRows]) {
            [timer invalidate];
            if (session) session->_poll = nil;
        }
    }];
    [NSRunLoop.mainRunLoop addTimer:_poll forMode:NSRunLoopCommonModes];
}

// Reads the sheet's rows once it has them, and runs what waited for them. Whether they are read.
- (BOOL)readRows {
    if (_groups) return YES;
    UITableView *table = tableIn(self.sheet.viewIfLoaded, 0);
    if (!table || rowCount(table) == 0) return NO;
    [table layoutIfNeeded];
    _table = table;
    NSMutableArray<NSArray<SGRSheetRow *> *> *groups = [NSMutableArray array];
    NSArray<SGRSheetRow *> *header = [self modRows:modRowsIn(table.tableHeaderView)];
    if (header.count) [groups addObject:header];
    NSUInteger read = 0;
    for (NSInteger section = 0; section < table.numberOfSections; section++) {
        NSMutableArray<SGRSheetRow *> *rows = [NSMutableArray array];
        for (NSInteger index = 0; index < [table numberOfRowsInSection:section]; index++) {
            SGRSheetRow *row = [self rowAt:[NSIndexPath indexPathForRow:index inSection:section] inTable:table];
            if (row) [rows addObject:row];
        }
        read += rows.count;
        if (rows.count) [groups addObject:rows];
    }
    NSArray<SGRSheetRow *> *footer = [self modRows:modRowsIn(table.tableFooterView)];
    if (footer.count) [groups addObject:footer];
    _groups = groups;
    CFTimeInterval after = CACurrentMediaTime() - _openedAt;
    SGLog(@"system menu: %lu of Spotify's rows and %lu of the mod's read%@", (unsigned long)read, (unsigned long)(header.count + footer.count),
          after > 0.5 ? [NSString stringWithFormat:@", %.1f s after the menu opened", after] : @"");
    if (self.items) [self matchQuick];

    NSArray<dispatch_block_t> *waiting = _whenRead;
    _whenRead = [NSMutableArray array];
    for (dispatch_block_t block in waiting) block();
    [self refreshQuickRow];
    return YES;
}

- (SGRSheetRow *)rowAt:(NSIndexPath *)path inTable:(UITableView *)table {
    UITableViewCell *cell = [table cellForRowAtIndexPath:path];
    if (!cell && [table.dataSource respondsToSelector:@selector(tableView:cellForRowAtIndexPath:)]) cell = [table.dataSource tableView:table cellForRowAtIndexPath:path];
    NSArray<UILabel *> *labels = labelsIn(cell);
    if (!labels.count) return nil;
    SGRSheetRow *row = [SGRSheetRow new];
    row.path = path;
    row.title = labels[0].text;
    if (labels.count > 1) row.subtitle = labels[1].text;
    row.image = glyphIn(cell);
    row.identifier = identifierIn(cell);
    row.enabled = rowEnabled(table, path, cell, labels[0]);
    return row;
}

- (NSArray<SGRSheetRow *> *)modRows:(NSArray<UIControl *> *)controls {
    NSMutableArray<SGRSheetRow *> *rows = [NSMutableArray array];
    for (UIControl *control in controls) {
        SGRSheetRow *row = [SGRSheetRow new];
        row.control = control;
        row.title = control.accessibilityLabel;
        row.image = glyphIn(control);
        row.enabled = YES;
        [rows addObject:row];
    }
    return rows;
}

// Marks Spotify's rows that are quick items, remembers which this kind of sheet has, and says so in the log,
// once a kind.
- (void)matchQuick {
    NSString *kind = self.kind ?: @"";
    NSMutableArray<NSString *> *found = [NSMutableArray array];
    NSMutableArray<NSString *> *every = [NSMutableArray array];
    for (NSArray<SGRSheetRow *> *group in _groups) {
        for (SGRSheetRow *row in group) {
            if (!row.path) continue;
            [every addObject:[NSString stringWithFormat:@"%@ (%@)", row.title, row.identifier ?: @"no id"]];
            NSString *title = [row.title.lowercaseString stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            for (NSArray<NSString *> *item in quickItems()) {
                if (![title isEqualToString:item[2]] || [found containsObject:item[2]]) continue;
                row.quick = item[2];
                [found addObject:item[2]];
            }
        }
    }
    if (!sg_quickSeen) sg_quickSeen = [NSMutableDictionary dictionary];
    sg_quickSeen[kind] = found;
    static NSMutableSet<NSString *> *logged;
    if (!logged) logged = [NSMutableSet set];
    if ([logged containsObject:kind] || logged.count >= 4) return;
    [logged addObject:kind];
    SGLog(@"system menu: the rows of a %@ sheet: %@", kind.length ? kind : @"player", [every componentsJoinedByString:@", "]);
    SGLog(@"system menu: quick items matched by title: %@", found.count ? [found componentsJoinedByString:@", "] : @"none");
}

#pragma mark the pick

// A quick item picked: its row fired, after the rows come in if they are not in yet, for up to kQuickWait;
// with no such row, or none in time, Spotify's sheet is shown, so the pick is never lost.
- (void)fireQuick:(NSString *)quick {
    if (_groups) {
        [self fireQuickNow:quick];
        return;
    }
    SGLog(@"system menu: %@ picked before the sheet had its rows, waiting up to %.0f s", quick, kQuickWait);
    _waiting = YES;
    __weak SGRMenuSession *weakSelf = self;
    [_whenRead addObject:^{ [weakSelf fireQuickNow:quick]; }];
    [self pollRows];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kQuickWait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SGRMenuSession *session = weakSelf;
        if (!session || !session->_waiting) return;
        session->_waiting = NO;
        SGLog(@"system menu: the sheet had no rows %.0f s after %@ was picked, Spotify's sheet shown", kQuickWait, quick);
        [session reveal];
    });
}

- (void)fireQuickNow:(NSString *)quick {
    _waiting = NO;
    SGRSheetRow *row = [self rowForQuick:quick];
    if (row) {
        [self fire:row];
        return;
    }
    SGLog(@"system menu: this sheet has no %@ row, Spotify's sheet shown", quick);
    [self reveal];
}

// A row of the sheet's fired, on the sheet still hidden under where the menu was.
- (void)fire:(SGRSheetRow *)row {
    UIViewController *presented = self.presented;
    if (!presented.presentingViewController || self.revealed) return;
    if (row.control) {
        [row.control sendActionsForControlEvents:UIControlEventTouchUpInside];
    } else {
        UITableView *table = _table;
        if (table.window) selectRow(table, row.path);
    }
    // A row that opens a page of its own inside the sheet leaves the sheet up: it is shown.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSettle * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIViewController *still = self.presented;
        if (!still.presentingViewController || still.isBeingDismissed || !still.viewIfLoaded.window) return;
        SGLog(@"system menu: the row picked left Spotify's sheet up, so it is shown");
        [self reveal];
    });
}

// The menu is gone. A pick is fired now, on the sheet still hidden under it; anything else leaves the sheet
// nothing to do, so it goes. Done a turn later, once the menu's own presentation is off the sheet.
- (void)menuEnded {
    if (self.ended) return;
    self.ended = YES;
    void (^pick)(void) = self.pick;
    self.pick = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *presented = self.presented;
        if (!presented.presentingViewController || self.revealed) return;
        if (!pick) {
            [presented.presentingViewController dismissViewControllerAnimated:NO completion:nil];
            return;
        }
        pick();
    });
}

// Spotify's sheet as it would have been: what the menu falls back to, and what a row that opens a page of
// the sheet's own leads to. Speed and pitch's block comes back into it (SGPlayerMenuReplaced).
- (void)reveal {
    if (self.revealed) return;
    self.revealed = YES;
    UIView *container = self.presented.presentationController.containerView;
    SGRAnimate(SGRMotionFade, ^{ container.alpha = 1; }, nil);
    [self.sheet.viewIfLoaded setNeedsLayout];
}

@end

static SGRMenuSession *sessionFor(UIViewController *controller) {
    for (UIViewController *vc = controller; vc; vc = vc.parentViewController) {
        SGRMenuSession *session = objc_getAssociatedObject(vc, &kSessionKey);
        if (session) return session;
    }
    return nil;
}

BOOL SGPlayerMenuReplaced(UIViewController *menu) {
    SGRMenuSession *session = sessionFor(menu);
    return session && !session.revealed;
}

#pragma mark - the ⋯

@interface SGRMenuTapWatcher : NSObject <UIGestureRecognizerDelegate>
@end

@implementation SGRMenuTapWatcher
// On touch down, not up: Spotify's own action may present the sheet from the same touch before a target
// added after it has run (Kit/SGRActionRow.m records the pinned ⋯ the same way).
- (void)pressed:(UIGestureRecognizer *)press {
    if (press.state != UIGestureRecognizerStateBegan) return;
    sg_claimButton = press.view;
    sg_claimAt = CACurrentMediaTime();
}
- (void)touchedDown:(UIView *)control {
    sg_claimButton = control;
    sg_claimAt = CACurrentMediaTime();
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}
@end

void SGRSystemMenuWatch(UIView *button, SGRMenuItems items, SGRMenuKind kind) {
    if (!button) return;
    objc_setAssociatedObject(button, &kItemsKey, items, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(button, &kKindKey, kind, OBJC_ASSOCIATION_COPY_NONATOMIC);
    if (objc_getAssociatedObject(button, &kWatchedKey)) return;
    static SGRMenuTapWatcher *watcher;
    if (!watcher) watcher = [SGRMenuTapWatcher new];
    objc_setAssociatedObject(button, &kWatchedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // An Encore button may read its touches through a gesture recognizer rather than as a control, so both
    // are watched.
    if ([button isKindOfClass:UIControl.class]) [(UIControl *)button addTarget:watcher action:@selector(touchedDown:) forControlEvents:UIControlEventTouchDown];
    UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc] initWithTarget:watcher action:@selector(pressed:)];
    press.minimumPressDuration = 0;
    press.cancelsTouchesInView = NO;
    press.delaysTouchesEnded = NO;
    press.delegate = watcher;
    [button addGestureRecognizer:press];
}

static SGRMenuAnchor *anchorIn(UIView *host) {
    SGRMenuAnchor *anchor = objc_getAssociatedObject(host, &kAnchorKey);
    if (!anchor) {
        anchor = [SGRMenuAnchor buttonWithType:UIButtonTypeCustom];
        anchor.showsMenuAsPrimaryAction = YES;
        anchor.userInteractionEnabled = NO;
        // VoiceOver reaches the ⋯ itself, whose tap brings the menu up the same way.
        anchor.isAccessibilityElement = NO;
        anchor.accessibilityElementsHidden = YES;
        anchor.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        anchor.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        objc_setAssociatedObject(host, &kAnchorKey, anchor, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (anchor.superview != host) [host addSubview:anchor];
    anchor.frame = host.bounds;
    return anchor;
}

// Whether this sheet is a watched ⋯'s, and if so its session, with the sheet's presentation now the menu's.
static SGRMenuSession *takeOver(UIViewController *presented) {
    if (!sheetIn(presented)) return nil;
    UIView *button = nil;
    if (sg_claimButton && CACurrentMediaTime() - sg_claimAt <= kClaimWindow) {
        button = sg_claimButton;
        sg_claimAt = 0;
    } else {
        button = SGRPinnedMoreRecentButton();
    }
    if (!button.window) return nil;
    static BOOL canPresent, checked;
    if (!checked) {
        checked = YES;
        canPresent = [UIControl instancesRespondToSelector:NSSelectorFromString(@"performPrimaryAction")]
                  || [UIContextMenuInteraction instancesRespondToSelector:NSSelectorFromString(@"_presentMenuAtLocation:")];
        if (!canPresent) SGLog(@"system menu: this iOS has no way to open a button's menu from code, Spotify's sheets stay");
    }
    if (!canPresent) return nil;
    SGRMenuSession *session = [SGRMenuSession new];
    session.presented = presented;
    session.anchor = anchorIn(button);
    session.items = objc_getAssociatedObject(button, &kItemsKey);
    SGRMenuKind kind = objc_getAssociatedObject(button, &kKindKey);
    session.kind = kind ? kind() : nil;
    objc_setAssociatedObject(presented, &kSessionKey, session, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return session;
}

%hook UIViewController
- (void)presentViewController:(UIViewController *)presented animated:(BOOL)animated completion:(void (^)(void))completion {
    SGRMenuSession *session = takeOver(presented);
    if (!session) {
        %orig;
        return;
    }
    %orig(presented, NO, ^{
        if (completion) completion();
        [session open];
    });
}
%end

%hook _TtC24ContextMenu_InternalImpl25ContextMenuViewController
// The first moment the presentation's container exists, before it has drawn a frame: hidden from here, its
// dimming too, so the screen does not darken under the menu.
// A sheet Spotify puts up some other way than presentViewController: (the player's ⋯ on a phone) is
// taken over here instead, from the same claim, and its menu opened once it has appeared.
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    SGRMenuSession *session = sessionFor((UIViewController *)self);
    if (!session && (session = takeOver((UIViewController *)self))) {
        static int logged;
        if (logged++ < 3) SGLog(@"system menu: a ⋯ sheet came up without presentViewController:, taken over as it appears");
    }
    if (session && !session.revealed) session.presented.presentationController.containerView.alpha = 0;
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    SGRMenuSession *session = sessionFor((UIViewController *)self);
    if (session && !session.opened) [session open];
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    SGRequireClasses(@[kSheetClass]);
}
