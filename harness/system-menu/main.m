// Redesigned/ContextMenu/ContextMenu.x and Redesigned/Player/PlayerMenu.m run for real against a mock of
// Spotify's context menu sheet (its class name, a table of rows with a delegate, a navigation controller
// around it), presented by a ⋯ button the way Spotify's is, and the system menu checked as it comes up.
//
//     THEOS=$HOME/theos ./build.sh && xcrun simctl install <udid> build/SystemMenuHarness.app
//     xcrun simctl launch --console-pty <udid> com.vitrine.systemmenuharness <scenario>
//
// Every scenario taps ⋯ at 1 s and prints PASS or FAIL lines, then `done` (README.md lists them). A pick or
// a submenu is opened the way a finger on the menu does it, through the menu view's own selection
// (_UIContextMenuView's _handleSelectionForElement:, the harness's only private call).
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "Redesigned/ContextMenu/ContextMenu.h"

void SGRPlayerMenuWatch(UIView *button);

static NSString *scenario(void) {
    NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
    return arguments.count > 1 ? arguments.lastObject : @"rows";
}

static BOOL is(NSString *run) {
    return [scenario() isEqualToString:run];
}

// The scenarios whose sheet gets its rows only when the harness gives them.
static BOOL rowsLate(void) {
    return is(@"loading") || is(@"quick") || is(@"quicklate") || is(@"podcast");
}

static void check(BOOL ok, NSString *what) {
    NSLog(@"[harness] %@ %@", ok ? @"PASS" : @"FAIL", what);
}

static void after(NSTimeInterval seconds, dispatch_block_t block) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), block);
}

// Runs `then` once `condition` holds, or after `limit` seconds whether or not it does.
static void waitFor(BOOL (^condition)(void), NSTimeInterval limit, dispatch_block_t then) {
    if (condition() || limit <= 0) {
        then();
        return;
    }
    after(0.1, ^{ waitFor(condition, limit - 0.1, then); });
}

#pragma mark - what the menu's code calls

static double sg_speed = 1;
static float sg_pitch, sg_reverb;
static BOOL sg_follows = YES, sg_animated;
double SGPlayerSpeed(void) { return sg_speed; }
BOOL SGPlayerSpeedAllowed(void) { return YES; }
void SGSetPlayerSpeed(double speed) { sg_speed = speed; NSLog(@"[harness] speed %.2f", speed); }
float SGPlayerPitch(void) { return sg_pitch; }
void SGSetPlayerPitch(float semitones) { sg_pitch = semitones; NSLog(@"[harness] pitch %.0f", semitones); }
BOOL SGPlayerPitchAvailable(void) { return YES; }
BOOL SGPlayerPitchFollowsSpeed(void) { return sg_follows; }
void SGSetPlayerPitchFollowsSpeed(BOOL follows) { sg_follows = follows; }
float SGPlayerReverb(void) { return sg_reverb; }
void SGPlayerSetReverb(float amount) { sg_reverb = amount; }
BOOL SGPlayerMenuOffersAnimatedArtwork(void) { return YES; }
BOOL SGPlayerMenuAnimatedArtwork(void) { return sg_animated; }
void SGPlayerMenuSetAnimatedArtwork(BOOL on) { sg_animated = on; NSLog(@"[harness] animated artwork %d", on); }
// The player's state, which the harness does not have: every sheet is of one kind.
@class SPTPlayerState;
SPTPlayerState *SGPlayerState(void) { return nil; }
NSString *SGURIString(id uri) { return nil; }
// The Kit's, which the harness does not build.
UIView *SGRPinnedMoreRecentButton(void) { return nil; }
void SGRAnimate(NSInteger motion, void (^animations)(void), void (^completion)(BOOL finished)) {
    [UIView animateWithDuration:0.2 animations:animations completion:completion];
}

// Every action and submenu the menu makes, by its title, so the harness can pick or open one.
static NSMutableDictionary<NSString *, UIMenuElement *> *sg_elements;
static IMP sg_actionWithTitle, sg_menuWithTitle;
static UIAction *recordAction(id self, SEL _cmd, NSString *title, UIImage *image, NSString *identifier, UIActionHandler handler) {
    UIAction *action = ((UIAction *(*)(id, SEL, NSString *, UIImage *, NSString *, UIActionHandler))sg_actionWithTitle)(self, _cmd, title, image, identifier, handler);
    if (title) sg_elements[title] = action;
    return action;
}
static UIMenu *recordMenu(id self, SEL _cmd, NSString *title, UIImage *image, NSString *identifier, UIMenuOptions options, NSArray *children) {
    UIMenu *menu = ((UIMenu *(*)(id, SEL, NSString *, UIImage *, NSString *, UIMenuOptions, NSArray *))sg_menuWithTitle)(self, _cmd, title, image, identifier, options, children);
    if (title.length) sg_elements[title] = menu;
    return menu;
}

#pragma mark - Spotify's sheet

static NSArray<NSArray<NSString *> *> *spotifyRows(void) {
    // A podcast's sheet, with no Add to playlist.
    if (is(@"podcast")) return @[@[@"text.badge.plus", @"Add to queue"], @[@"square.stack", @"Go to show"], @[@"square.and.arrow.up", @"Share"]];
    return @[@[@"plus.circle", @"Add to playlist"], @[@"text.badge.plus", @"Add to queue"], @[@"square.stack", @"Go to album"],
             @[@"square.and.arrow.up", @"Share"], @[@"quote.bubble", @"Lyrics"]];
}

static NSString *sg_selected;

// A row of the mod's own in the sheet's header, as Redesigned/Playlist/PlaylistMenu.x puts Sort there.
@interface SGHarnessSortRow : UIControl
@end
@implementation SGHarnessSortRow
- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    UIImageView *glyph = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"arrow.up.arrow.down"]];
    glyph.frame = CGRectMake(16, 16, 24, 24);
    [self addSubview:glyph];
    self.accessibilityLabel = @"Sort";
    [self addTarget:self action:@selector(fired) forControlEvents:UIControlEventTouchUpInside];
    return self;
}
// As the playlist's row does: the sheet goes first, then Spotify's own Sort is fired.
- (void)fired {
    UIViewController *sheet = nil;
    for (UIResponder *responder = self; responder && !sheet; responder = responder.nextResponder) {
        if ([responder isKindOfClass:UINavigationController.class]) sheet = (UIViewController *)responder;
    }
    [sheet.presentingViewController dismissViewControllerAnimated:YES completion:^{ NSLog(@"[harness] sort fired"); }];
}
@end

@interface _TtC24ContextMenu_InternalImpl25ContextMenuViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic) BOOL loaded;
@end

@implementation _TtC24ContextMenu_InternalImpl25ContextMenuViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.07 alpha:1];
    self.loaded = !rowsLate();
    self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.table.rowHeight = 56;
    self.table.dataSource = self;
    self.table.delegate = self;
    [self.table registerClass:UITableViewCell.class forCellReuseIdentifier:@"row"];
    if (is(@"sort")) {
        UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 100, 56)];
        SGHarnessSortRow *sort = [[SGHarnessSortRow alloc] initWithFrame:header.bounds];
        sort.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [header addSubview:sort];
        self.table.tableHeaderView = header;
    }
    [self.view addSubview:self.table];
}

// What Spotify does once its item factories are done.
- (void)giveRows {
    self.loaded = YES;
    [self.table reloadData];
    NSLog(@"[harness] the sheet has its rows");
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.loaded ? spotifyRows().count : 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"row" forIndexPath:indexPath];
    UIListContentConfiguration *content = cell.defaultContentConfiguration;
    NSString *title = spotifyRows()[indexPath.row][1];
    content.text = title;
    content.image = [UIImage systemImageNamed:spotifyRows()[indexPath.row][0]];
    // Lyrics greyed out, as for a track no source has them for.
    content.textProperties.color = [title isEqualToString:@"Lyrics"] ? [UIColor colorWithWhite:1 alpha:0.3] : UIColor.whiteColor;
    cell.contentConfiguration = content;
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    return ![spotifyRows()[indexPath.row][1] isEqualToString:@"Lyrics"];
}

// Share opens a page of its own inside the sheet; every other row does its thing and closes the sheet.
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *row = spotifyRows()[indexPath.row][1];
    sg_selected = row;
    NSLog(@"[harness] selected %@", row);
    if ([row isEqualToString:@"Share"]) {
        UIViewController *page = [UIViewController new];
        page.view.backgroundColor = UIColor.darkGrayColor;
        [self.navigationController pushViewController:page animated:YES];
        return;
    }
    [self.navigationController.presentingViewController dismissViewControllerAnimated:YES completion:nil];
}

@end

#pragma mark - the player

@interface SGHarnessPlayer : UIViewController
@property (nonatomic, strong) UIButton *more;
@property (nonatomic, weak) UINavigationController *sheet;
@end

@implementation SGHarnessPlayer

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.25 green:0.1 blue:0.2 alpha:1];
    self.more = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.more setImage:[UIImage systemImageNamed:@"ellipsis"] forState:UIControlStateNormal];
    self.more.frame = CGRectMake(330, 70, 48, 48);
    self.more.accessibilityIdentifier = @"Context menu";
    [self.more addTarget:self action:@selector(moreTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.more];
    SGRPlayerMenuWatch(self.more);
}

// What Spotify's ⋯ does: build its sheet and present it, animated.
- (void)moreTapped {
    UINavigationController *sheet = [[UINavigationController alloc] initWithRootViewController:[_TtC24ContextMenu_InternalImpl25ContextMenuViewController new]];
    self.sheet = sheet;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)tapMore {
    [self.more sendActionsForControlEvents:UIControlEventTouchDown];
    [self.more sendActionsForControlEvents:UIControlEventTouchUpInside];
}

- (_TtC24ContextMenu_InternalImpl25ContextMenuViewController *)mockSheet {
    return (id)self.sheet.viewControllers.firstObject;
}

- (UIButton *)anchor {
    for (UIView *view in self.more.subviews) if ([NSStringFromClass(view.class) isEqualToString:@"SGRMenuAnchor"]) return (UIButton *)view;
    return nil;
}

static UIView *menuView(UIView *root) {
    if ([NSStringFromClass(root.class) isEqualToString:@"_UIContextMenuView"]) return root;
    for (UIView *child in root.subviews) {
        UIView *found = menuView(child);
        if (found) return found;
    }
    return nil;
}

static UIView *openMenu(void) {
    for (UIWindowScene *scene in UIApplication.sharedApplication.connectedScenes) {
        for (UIWindow *window in scene.windows) {
            UIView *found = menuView(window);
            if (found) return found;
        }
    }
    return nil;
}

// Whether a label in the open menu reads exactly `title` (case and all, so Spotify's "Add to queue" and the
// quick "Add to Queue" are told apart).
static BOOL menuShows(NSString *title) {
    __block BOOL found = NO;
    UIView *menu = openMenu();
    void (^walk)(UIView *);
    __block __weak void (^weakWalk)(UIView *);
    weakWalk = walk = ^(UIView *view) {
        if ([view isKindOfClass:UILabel.class] && !view.hidden && view.window && [((UILabel *)view).text isEqualToString:title]) found = YES;
        for (UIView *child in view.subviews) weakWalk(child);
    };
    if (menu) walk(menu);
    return found;
}

static BOOL menuShowsAll(NSArray<NSString *> *titles) {
    for (NSString *title in titles) if (!menuShows(title)) return NO;
    return YES;
}

static BOOL menuShowsAny(NSArray<NSString *> *titles) {
    for (NSString *title in titles) if (menuShows(title)) return YES;
    return NO;
}

// Picks an action, or opens a submenu.
static void pick(NSString *title) {
    UIView *menu = openMenu();
    UIMenuElement *element = sg_elements[title];
    NSLog(@"[harness] picking %@ (%@)", title, element ? @"made" : @"never made");
    if (menu && element) ((void (*)(id, SEL, id))objc_msgSend)(menu, NSSelectorFromString(@"_handleSelectionForElement:"), element);
}

- (CGFloat)sheetAlpha {
    UIView *container = self.sheet.presentationController.containerView;
    return container ? container.alpha : -1;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    static BOOL started;
    if (started) return;
    started = YES;
    NSString *run = scenario();
    after(1, ^{ [self tapMore]; });
    // The simulator takes a second or more over the first sheet it presents, so what follows is timed from
    // the presentation's end (the sheet's view in a window) rather than from the tap.
    [self whenSheetUp:^{ [self runScenario:run]; }];
}

- (void)whenSheetUp:(dispatch_block_t)then {
    __block int tries = 0;
    __block __weak void (^weakPoll)(void);
    void (^poll)(void) = ^{
        if (self.sheet.viewIfLoaded.window && !self.sheet.isBeingPresented) {
            after(0.4, then);
            return;
        }
        if (++tries > 100) {
            check(NO, @"Spotify's sheet came up within 10 s");
            exit(0);
        }
        after(0.1, weakPoll);
    };
    weakPoll = poll;
    after(1.1, poll);
}

static NSArray<NSString *> *quickTitles(void) {
    return @[@"Share", @"Add to Playlist", @"Add to Queue"];
}

- (void)runScenario:(NSString *)run {
    void (^finish)(void) = ^{
        NSLog(@"[harness] done");
        exit(0);
    };
    check(self.sheet.presentingViewController == self, @"Spotify's sheet is presented");
    if ([run isEqualToString:@"fallback"]) {
        check(self.sheetAlpha == 1, [NSString stringWithFormat:@"with no way to open the menu the sheet shows at once (container alpha %.2f)", self.sheetAlpha]);
        check(!openMenu(), @"no menu came up");
        check(!self.anchor.userInteractionEnabled, @"the anchor takes no touches");
        after(1.2, finish);
        return;
    }
    check(self.sheetAlpha == 0, [NSString stringWithFormat:@"the sheet is hidden (container alpha %.2f)", self.sheetAlpha]);
    check(openMenu() != nil, @"the system menu is up");
    check(self.anchor.userInteractionEnabled, @"the anchor takes touches while its menu is up");
    if (rowsLate()) check(openMenu() && !self.mockSheet.loaded, @"the menu came up before the sheet had its rows");
    check(menuShowsAll(@[@"Speed, Pitch & Reverb", @"Show Animated Artwork", @"More"]), @"the player's own items and More are in it");
    check(menuShowsAll(quickTitles()), @"the quick row has Share, Add to Playlist and Add to Queue");
    check(!menuShowsAny(@[@"Go to album", @"Go to show", @"Playback Speed", @"Lyrics"]), @"Spotify's other rows and the speed steps are not at the top level");

    // Held open for a screenshot.
    if ([run isEqualToString:@"show"]) return;
    if ([run isEqualToString:@"showmore"] || [run isEqualToString:@"showsound"]) {
        after(0.4, ^{ pick([run isEqualToString:@"showmore"] ? @"More" : @"Speed, Pitch & Reverb"); });
        return;
    }

    // The simulator takes up to a second or two over the menu's own dismissal, so the checks after a pick
    // wait for what they look for, up to a limit, and report what they then find.
    BOOL (^gone)(void) = ^BOOL { return !openMenu() && !self.sheet; };
    void (^pickAndGo)(NSString *, NSString *) = ^(NSString *title, NSString *selected) {
        pick(title);
        waitFor(gone, 5, ^{
            check(!self.sheet, @"the sheet went with the row's action");
            check(!self.anchor.userInteractionEnabled, @"the anchor gave its touches back");
            if (selected) check([sg_selected isEqualToString:selected], [NSString stringWithFormat:@"Spotify's %@ was selected (%@)", selected, sg_selected]);
            finish();
        });
    };

    if ([run isEqualToString:@"rows"] || [run isEqualToString:@"sort"]) {
        after(0.4, ^{
            pick(@"More");
            waitFor(^BOOL { return menuShows(@"Go to album"); }, 3, ^{
                check(menuShowsAll(@[@"Go to album", @"Lyrics"]), @"More holds the rest of Spotify's rows");
                check(!menuShowsAny(@[@"Add to playlist", @"Add to queue"]), @"More leaves out the rows the quick row has");
                UIMenuElement *lyrics = sg_elements[@"Lyrics"];
                check([lyrics isKindOfClass:UIAction.class] && (((UIAction *)lyrics).attributes & UIMenuElementAttributesDisabled), @"the row Spotify greys out is disabled");
                if ([run isEqualToString:@"sort"]) check(menuShows(@"Sort"), @"the mod's row in the sheet's header is in More");
                after(0.4, ^{
                    if ([run isEqualToString:@"sort"]) {
                        pick(@"Sort");
                        waitFor(gone, 5, ^{
                            check(!self.sheet, @"the sheet went with Sort's action");
                            finish();
                        });
                        return;
                    }
                    pickAndGo(@"Go to album", @"Go to album");
                });
            });
        });
        return;
    }
    if ([run isEqualToString:@"loading"]) {
        after(0.4, ^{
            pick(@"More");
            after(0.6, ^{
                check(openMenu() && !menuShows(@"Go to album"), @"More has no rows before the sheet has them");
                [self.mockSheet giveRows];
                waitFor(^BOOL { return menuShows(@"Go to album"); }, 5, ^{
                    check(openMenu() != nil, @"the menu waited for the rows, still up");
                    check(menuShows(@"Go to album"), @"Spotify's rows came into the open More");
                    after(0.4, ^{ pickAndGo(@"Go to album", @"Go to album"); });
                });
            });
        });
        return;
    }
    if ([run isEqualToString:@"quick"] || [run isEqualToString:@"quicklate"]) {
        BOOL late = [run isEqualToString:@"quicklate"];
        after(0.4, ^{
            pick(late ? @"Add to Playlist" : @"Add to Queue");
            waitFor(^BOOL { return !openMenu(); }, 5, ^{
                check(!openMenu(), @"the menu closed on the pick");
                check(self.sheet.presentingViewController && self.sheetAlpha == 0, @"the sheet stays hidden while the pick waits for its row");
                if (!late) {
                    // The rows come only after the menu has gone, so the pick has to wait for them.
                    after(1, ^{
                        [self.mockSheet giveRows];
                        waitFor(gone, 5, ^{
                            check(!self.sheet, @"the sheet went with the row's action");
                            check([sg_selected isEqualToString:@"Add to queue"], [NSString stringWithFormat:@"the late row Add to queue was selected (%@)", sg_selected]);
                            check(!self.anchor.userInteractionEnabled, @"the anchor gave its touches back");
                            finish();
                        });
                    });
                    return;
                }
                waitFor(^BOOL { return self.sheetAlpha == 1; }, 4, ^{
                    check(self.sheet.presentingViewController && self.sheetAlpha == 1, [NSString stringWithFormat:@"with no rows in 2 s Spotify's sheet is shown (container alpha %.2f)", self.sheetAlpha]);
                    check(!sg_selected, @"nothing was selected");
                    finish();
                });
            });
        });
        return;
    }
    if ([run isEqualToString:@"podcast"]) {
        after(0.4, ^{
            [self.mockSheet giveRows];
            waitFor(^BOOL { return !menuShows(@"Add to Playlist"); }, 3, ^{
                check(!menuShows(@"Add to Playlist"), @"once the rows are in, the quick item this sheet has no row for is gone");
                check(menuShowsAll(@[@"Share", @"Add to Queue", @"More"]), @"the other quick items and More are still there");
                pick(@"More");
                waitFor(^BOOL { return menuShows(@"Go to show"); }, 3, ^{
                    check(menuShows(@"Go to show") && !menuShowsAny(@[@"Add to queue"]), @"More holds the podcast's other rows");
                    after(0.4, ^{ pickAndGo(@"Go to show", @"Go to show"); });
                });
            });
        });
        return;
    }
    if ([run isEqualToString:@"close"]) {
        after(0.4, ^{
            [self.anchor.contextMenuInteraction dismissMenu];
            waitFor(gone, 5, ^{
                check(!self.sheet, @"closing the menu with no pick dismissed the sheet");
                check(!self.anchor.userInteractionEnabled, @"the anchor gave its touches back");
                [self tapMore];
                waitFor(^BOOL { return openMenu() && self.sheet && !self.sheet.isBeingPresented; }, 5, ^{
                    check(openMenu() != nil && self.sheetAlpha == 0, @"a second tap opens the menu again over a hidden sheet");
                    finish();
                });
            });
        });
        return;
    }
    if ([run isEqualToString:@"subpage"]) {
        after(0.4, ^{
            pick(@"Share");
            waitFor(^BOOL { return !openMenu() && self.sheetAlpha == 1; }, 5, ^{
                check(!openMenu(), @"the menu closed on the pick");
                check(!self.anchor.userInteractionEnabled, @"the anchor gave its touches back");
                check([sg_selected isEqualToString:@"Share"], @"the quick Share selected Spotify's Share");
                check(self.sheet.presentingViewController && self.sheetAlpha == 1, [NSString stringWithFormat:@"a row that keeps the sheet up shows it (container alpha %.2f)", self.sheetAlpha]);
                finish();
            });
        });
        return;
    }
    if ([run isEqualToString:@"animated"]) {
        after(0.4, ^{
            pick(@"Show Animated Artwork");
            waitFor(gone, 5, ^{
                check(!openMenu(), @"the menu closed on the pick");
                check(sg_animated, @"Show Animated Artwork switched it on");
                check(!self.sheet, @"the sheet went with the menu");
                finish();
            });
        });
        return;
    }
    check(NO, [NSString stringWithFormat:@"no scenario %@", run]);
    finish();
}

@end

@interface SGHarnessApp : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation SGHarnessApp
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [SGHarnessPlayer new];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

static void nothing(id self, SEL _cmd) {}
static void nothingAt(id self, SEL _cmd, CGPoint location) {}

// Before every %ctor, so the redesign's gate reads on.
__attribute__((constructor(101))) static void sgr_harnessDefaults(void) {
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"spotifyglass.redesign"];
    sg_elements = [NSMutableDictionary dictionary];
    Method make = class_getClassMethod(UIAction.class, @selector(actionWithTitle:image:identifier:handler:));
    sg_actionWithTitle = method_setImplementation(make, (IMP)recordAction);
    Method menu = class_getClassMethod(UIMenu.class, @selector(menuWithTitle:image:identifier:options:children:));
    sg_menuWithTitle = method_setImplementation(menu, (IMP)recordMenu);
    // An OS where neither way of opening a button's menu from code does anything.
    if (is(@"fallback")) {
        class_replaceMethod(UIButton.class, NSSelectorFromString(@"performPrimaryAction"), (IMP)nothing, "v@:");
        class_replaceMethod(UIContextMenuInteraction.class, NSSelectorFromString(@"_presentMenuAtLocation:"), (IMP)nothingAt, "v@:{CGPoint=dd}");
    }
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(SGHarnessApp.class));
    }
}
