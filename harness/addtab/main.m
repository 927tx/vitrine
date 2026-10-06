// Add a Tab harness: Shared/Navigation/AddTabSheet.m and TabIcons.m run for real in the simulator, over a
// stand-in for Spotify's Encore classes (a few glyphs drawn as SF Symbols), with Links.x compiled as it
// is (no dispatcher, so every link is "unknown" and let through, as before Spotify has set it up).
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import "Shared/Navigation/AddTabSheet.h"
#import "Shared/Navigation/TabIcons.h"

#pragma mark - Spotify's classes, by the names TabIcons.m looks for

@interface SGHarnessGlyph : NSObject
@property (nonatomic, copy) NSString *name;
@end
@implementation SGHarnessGlyph
@end

@interface SPTEncoreIcon : NSObject
@end
@implementation SPTEncoreIcon
static id glyph(NSString *name) { SGHarnessGlyph *g = [SGHarnessGlyph new]; g.name = name; return g; }
+ (id)home { return glyph(@"home"); }
+ (id)search { return glyph(@"search"); }
+ (id)heart { return glyph(@"heart"); }
+ (id)podcasts { return glyph(@"podcasts"); }
+ (id)star { return glyph(@"star"); }
+ (id)playlist { return glyph(@"playlist"); }
+ (id)plus { return glyph(@"plus"); }
+ (id)queue { return glyph(@"queue"); }
// Not glyphs: one takes an argument, one returns no object, one has no name.
+ (id)iconNamed:(NSString *)name { return glyph(name); }
+ (NSInteger)count { return 8; }
+ (id)helper { return [NSObject new]; }
@end

@interface SPTEncoreIconView : UIImageView
- (instancetype)initWithIcon:(id)icon;
- (void)setForegroundColor:(UIColor *)color;
@end
@implementation SPTEncoreIconView
- (instancetype)initWithIcon:(id)icon {
    NSDictionary *symbols = @{@"home": @"house", @"search": @"magnifyingglass", @"heart": @"heart", @"podcasts": @"mic",
                              @"star": @"star", @"playlist": @"music.note.list", @"plus": @"plus", @"queue": @"list.bullet"};
    if (!(self = [super initWithImage:[UIImage systemImageNamed:symbols[[icon name]] ?: @"questionmark"]])) return nil;
    self.contentMode = UIViewContentModeScaleAspectFit;
    return self;
}
- (void)setForegroundColor:(UIColor *)color { self.tintColor = color; }
@end

#pragma mark - the app

@interface SGHarnessRoot : UIViewController
@end
@implementation SGHarnessRoot
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
}
@end

@interface SGHarnessScene : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

static void after(double seconds, dispatch_block_t block) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), block);
}

static UITableViewController *topPage(UIViewController *root) {
    UINavigationController *nav = (UINavigationController *)root.presentedViewController;
    return (UITableViewController *)nav.topViewController;
}

static void tap(UITableViewController *page, NSInteger section, NSInteger row) {
    NSLog(@"[harness] tap %ld.%ld on %@", (long)section, (long)row, page.title);
    [page.tableView.delegate tableView:page.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:section]];
}

@implementation SGHarnessScene

// Launch words: `sheet` the sheet as it opens; `preset` Liked Songs picked from Choose a Link; `glyphs`
// Choose an Icon on Encore; `symbols` Choose an Icon searching SF Symbols for "heart"; `pick` one of its results
// tapped mid-search; `added` Liked Songs with
// the SF Symbol music.mic added, the tab logged. The glyph enumeration and the symbol list's size and time are logged.
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    SGHarnessRoot *root = [SGHarnessRoot new];
    self.window.rootViewController = root;
    [self.window makeKeyAndVisible];
    NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
    NSString *mode = args.count > 1 ? args[1] : @"sheet";

    NSLog(@"[harness] glyphs %@", SGEncoreGlyphNames());
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    SGLoadSymbolNames(^(NSArray<NSString *> *names) {
        NSLog(@"[harness] %lu symbols in %.2f s, first %@, has heart.circle %d, has a .ar %d", (unsigned long)names.count,
              CFAbsoluteTimeGetCurrent() - start, names.firstObject, [names containsObject:@"heart.circle"],
              [names containsObject:@"0.circle.ar"]);
    });

    NSArray *presets = @[
        @{SGTabTitle: @"Liked Songs", SGTabURI: @"spotify:collection:tracks", SGTabIcon: @"heart"},
        @{SGTabTitle: @"Podcasts", SGTabURI: @"spotify:collection:podcasts", SGTabIcon: @"podcasts"},
        @{SGTabTitle: @"Queue", SGTabURI: @"spotify:now-playing:queue", SGTabIcon: @"queue"},
    ];
    after(0.5, ^{
        SGPresentAddTabSheet(root, presets, ^(NSDictionary *tab) { NSLog(@"[harness] added %@", tab); });
    });
    if ([mode isEqualToString:@"sheet"]) return;
    after(2.5, ^{ tap(topPage(root), 1, 0); });
    after(3.5, ^{
        if ([mode isEqualToString:@"preset"] || [mode isEqualToString:@"added"]) tap(topPage(root), 0, 0);
        else [topPage(root).navigationController popViewControllerAnimated:NO];
    });
    if ([mode isEqualToString:@"preset"]) return;
    after(4.5, ^{ tap(topPage(root), 1, 1); });
    if ([mode isEqualToString:@"glyphs"]) return;
    after(5.5, ^{
        UITableViewController *page = topPage(root);
        UISegmentedControl *sets = (UISegmentedControl *)page.navigationItem.titleView;
        sets.selectedSegmentIndex = 1;
        [sets sendActionsForControlEvents:UIControlEventValueChanged];
        if (![mode isEqualToString:@"symbols"] && ![mode isEqualToString:@"pick"]) return;
        page.navigationItem.searchController.active = YES;
        page.navigationItem.searchController.searchBar.text = @"heart";
        [page.navigationItem.searchController.searchResultsUpdater updateSearchResultsForSearchController:page.navigationItem.searchController];
    });
    if ([mode isEqualToString:@"symbols"]) return;
    // `pick`: a result tapped while the search is still up, as a finger would.
    if ([mode isEqualToString:@"pick"]) {
        after(7.0, ^{
            UITableViewController *page = topPage(root);
            NSLog(@"[harness] before pick: active %d, page presents %@, nav presents %@, search bar in window %d, rows %ld", page.navigationItem.searchController.active,
                  page.presentedViewController, page.navigationController.presentedViewController,
                  page.navigationItem.searchController.searchBar.window != nil, (long)[page.tableView numberOfRowsInSection:0]);
            tap(page, 0, 0);
        });
        after(9.5, ^{ NSLog(@"[harness] after pick: %@", topPage(root).title); });
        return;
    }
    after(7.0, ^{
        tap(topPage(root), 0, 6);
    });
    after(8.5, ^{
        UIBarButtonItem *add = topPage(root).navigationItem.rightBarButtonItem;
        NSLog(@"[harness] add enabled %d", add.enabled);
        ((void (*)(id, SEL))objc_msgSend)(add.target, add.action);
    });
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, nil);
    }
}
