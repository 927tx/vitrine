// Settings: a Mod Settings row at the end of Spotify's settings list opens the mod's own page, its rows
// grouped by what they are as the system Settings app groups its own, in cards with no headings: what the
// app looks like (Redesigned UI's switch, Appearance, Tab bar), the screens a page of its own changes
// (Player, Lyrics, and Albums & artists or, in the native look, Home & Library), the features that work
// under either look (Sing, Spatial voice, Audio effects, Vibrations, Live Activity, AirPods gestures, Listening stats),
// the system's side (Lock screen; Premium, ads & privacy), the advanced pages (Labs, All flags, a
// searchable list of every flag with an override per flag) and Mod, the build, its updates and links. The
// same row leads the side drawer's list (trees/test6.txt), above Your plan, so the page is a tap from
// Home, and holding Home on the tab bar opens it too. The tweaks read the switches when they run, so a
// change shows after Spotify restarts; the tab editor on the Tab bar page applies as soon as the bar lays
// out again.
//
// Tree (trees/settings.txt): SettingsListViewController.view > SettingsListCollectionView of
//   Element_List cells 402x56: 24pt icon at x 12, 13pt white title and 11pt grey subtitle at
//   x 48, 12pt chevron on the right. A pushed page (trees/settings notifications opened.txt) is a
//   UITableView bg #121212: header with an 11pt grey description at (16, 24), 53pt cells with the
#import "Core/SGCore.h"
#import "Settings/SGPage.h"
#import "Settings/SGPageStyle.h"
#import "Settings/SGModPage.h"
#import "Native/Home/Home.h"
#import "Shared/AdBlock/AdBlock.h"
#import "Shared/Flags/Flags.h"
#import "Shared/AudioEffects/AudioEffectsPage.h"
#import "Shared/LiveActivity/LiveActivity.h"
#import "Shared/ListeningStats/ListeningStats.h"
#import "Shared/HeadGestures/HeadGestures.h"
#import "Shared/Player/PlayerSettings.h"
#import "Shared/Sing/Sing.h"
#import "Shared/Haptics/Haptics.h"
#import "App/About/About.h"
#import "App/Onboarding/Onboarding.h"
#import "Redesigned/Album/Album.h"
#import "Pages.h"

static const CGFloat kRowHeight = 56;
static char kRowKey, kInsetKey;

// Each part of Spotify on a tile of its own colour, as Settings lists its own, so a row is found by its colour.
static SGModRow *pageRow(NSString *title, NSString *symbol, UIColor *color, UIViewController *(^page)(void)) {
    return SGWithTile(SGPageRow(title, page), symbol, color);
}

static UIViewController *modSettingsPage(void) {
    // Opening the page is the only thing that asks; the cache keeps it to once every six hours.
    SGCheckForUpdate(NO);
    NSMutableArray<SGModSection *> *sections = [NSMutableArray array];
    // A build the lock screen cannot open leads the page, above the tweaks: it is the one thing here
    // that no switch can put right, and it is worth reading before anything else.
    SGModRow *signing = SGSigningWarningRow();
    NSMutableArray<SGModRow *> *warnings = [NSMutableArray arrayWithArray:SGEnvironmentWarningRows()];
    if (signing) [warnings insertObject:signing atIndex:0];
    if (warnings.count) [sections addObject:SGSection(nil, warnings)];

    // The rows of one look are asked again as Redesigned UI is flipped, so the page shows what the restart brings.
    BOOL (^redesigned)(void) = ^BOOL { return SGRedesignedUIStored(); };
    BOOL (^native)(void) = ^BOOL { return !SGRedesignedUIStored(); };

    [sections addObject:SGSection(nil, @[
        SGRedesignedUIRow(),
        pageRow(@"Appearance", @"paintpalette", UIColor.systemBlueColor, ^UIViewController *{ return SGAppearancePage(); }),
        pageRow(@"Tab bar", @"dock.rectangle", UIColor.systemIndigoColor, ^UIViewController *{ return SGNavbarPage(); }),
    ])];

    // Home & Library holds only the native look's switches; the redesign has its album and artist pages instead.
    SGModRow *albums = pageRow(@"Albums & artists", @"square.stack", UIColor.systemCyanColor, ^UIViewController *{ return SGRAlbumSettingsPage(); });
    albums.visible = redesigned;
    SGModRow *home = pageRow(@"Home & Library", @"house", UIColor.systemCyanColor, ^UIViewController *{ return SGHomeSettingsPage(); });
    home.visible = native;
    [sections addObject:SGSection(nil, @[
        pageRow(@"Player", @"play.circle", UIColor.systemPinkColor, ^UIViewController *{ return SGPlayerSettingsPage(); }),
        pageRow(@"Lyrics", @"quote.bubble", UIColor.systemPurpleColor, ^UIViewController *{ return SGLyricsSettingsPage(); }),
        albums,
        home,
    ])];

    // Sing and the audio effects work on the sound, so both looks have them, each saying beside the chevron
    // whether it is on, how far Sing's voice model has come or how many effects are on.
    SGModRow *sing = pageRow(@"Sing", @"music.mic", UIColor.systemRedColor, ^UIViewController *{ return SGSingSettingsPage(); });
    sing.value = ^NSString *{ return SGSingSummary(); };
    SGModRow *audioEffects = pageRow(@"Audio effects", @"slider.vertical.3", UIColor.systemOrangeColor, ^UIViewController *{ return SGDSPSettingsPage(); });
    audioEffects.value = ^NSString *{ return SGDSPSummary(); };
    // Spatial voice is Sing's too, and shows where the iPhone reads headphone motion, as on Sing's page.
    SGModRow *spatial = pageRow(@"Spatial voice", @"person.wave.2", UIColor.systemIndigoColor, ^UIViewController *{ return SGSpatialVoiceSettingsPage(); });
    spatial.value = ^NSString *{ return SGSingSpatial() ? @"On" : @"Off"; };
    spatial.visible = ^BOOL { return SGSingSpatialAvailable(); };
    // Vibrations hook Spotify's own controls and its audio, so they answer under either look; the row says which are on.
    SGModRow *vibrations = pageRow(@"Vibrations", @"iphone.radiowaves.left.and.right", UIColor.systemPinkColor, ^UIViewController *{ return SGVibrationsSettingsPage(); });
    vibrations.value = ^NSString *{ return SGVibrationsSummary(); };
    NSMutableArray<SGModRow *> *features = [NSMutableArray arrayWithObjects:sing, spatial, audioEffects, vibrations, nil];
    // The Live Activity works under both looks, where ActivityKit's card does.
    if (@available(iOS 17.0, *)) {
        SGModRow *liveActivity = pageRow(@"Live Activity", @"platter.filled.top.iphone", UIColor.systemTealColor, ^UIViewController *{ return SGLiveActivitySettingsPage(); });
        liveActivity.value = ^NSString *{ return SGLiveActivitySummary(); };
        [features addObject:liveActivity];
    }
    [features addObjectsFromArray:@[
        pageRow(@"AirPods gestures", @"airpods.pro", UIColor.systemGrayColor, ^UIViewController *{ return SGHeadGesturesSettingsPage(); }),
        pageRow(@"Listening stats", @"chart.bar", UIColor.systemGreenColor, ^UIViewController *{ return SGListeningStatsPage(); }),
    ]];
    [sections addObject:SGSection(nil, features)];

    SGModRow *mod = pageRow(@"Mod", @"info.circle", UIColor.systemGrayColor, ^UIViewController *{ return SGAboutPage(); });
    mod.value = ^NSString *{ return @(SG_VERSION); };
    [sections addObjectsFromArray:@[
        SGSection(nil, @[
            pageRow(@"Lock screen", @"lock", UIColor.systemGrayColor, ^UIViewController *{ return SGLockScreenWidgetPage(); }),
            pageRow(@"Premium, ads & privacy", @"crown", UIColor.systemBlueColor, ^UIViewController *{ return SGAdsSettingsPage(); }),
        ]),
        SGSection(nil, @[
            pageRow(@"Labs", @"testtube.2", UIColor.systemMintColor, ^UIViewController *{ return SGLabsPage(); }),
            pageRow(@"All flags", @"flag", UIColor.systemGrayColor, ^UIViewController *{ return SGAllFlagsPage(); }),
        ]),
        SGSection(nil, @[mod]),
    ]];
    return [[SGModPage alloc] initWithTitle:@"Vitrine" intro:nil sections:sections footer:nil];
}

#pragma mark - row in the settings list and the side drawer

// The last row of Spotify's settings list, chevron and all, or the first of the side drawer's,
// drawn like the drawer's own rows: no chevron, icon and title 4pt further in.
@interface SGModSettingsRow : UIControl
@property (nonatomic) BOOL drawer;
@end

@implementation SGModSettingsRow {
    UIImageView *_icon;
    UILabel *_title;
    UIImageView *_chevron;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _icon = SGSymbolView(@"slider.horizontal.3", 20, UIImageSymbolWeightRegular, 24);
    _title = [UILabel new];
    _title.text = @"Mod Settings";
    _title.textColor = UIColor.whiteColor;
    _chevron = SGSymbolView(@"chevron.right", 11, UIImageSymbolWeightSemibold, 12);
    for (UIView *v in @[_icon, _title, _chevron]) [self addSubview:v];
    [self addTarget:self action:@selector(open) forControlEvents:UIControlEventTouchUpInside];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _title.font = SGSpotifyListFont();
    CGFloat width = self.bounds.size.width, height = self.bounds.size.height, lead = self.drawer ? 4 : 0;
    _icon.frame = CGRectMake(12 + lead, (height - 24) / 2, 24, 24);
    _title.frame = CGRectMake(48 + lead, 0, width - 96, height);
    _chevron.frame = CGRectMake(width - 24, (height - 12) / 2, 12, 12);
    _chevron.hidden = self.drawer;
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.alpha = highlighted ? 0.5 : 1;
}

static UINavigationController *navigationIn(UIViewController *page) {
    if ([page isKindOfClass:UINavigationController.class]) return (UINavigationController *)page;
    for (UIViewController *child in page.childViewControllers) {
        UINavigationController *found = navigationIn(child);
        if (found) return found;
    }
    return nil;
}

// The drawer is presented over the app, so its row closes it first and pushes onto the stack it
// was covering, the way the drawer's own rows open their pages.
- (void)open {
    UIViewController *owner = nil;
    for (UIResponder *r = self; r && !owner; r = r.nextResponder) {
        if ([r isKindOfClass:UIViewController.class]) owner = (UIViewController *)r;
    }
    UIViewController *presenting = self.drawer ? owner.presentingViewController : nil;
    if (!presenting) {
        SGShowPage(owner, modSettingsPage());
        return;
    }
    [presenting dismissViewControllerAnimated:YES completion:^{
        SGShowPage(navigationIn(presenting).topViewController ?: presenting, modSettingsPage());
    }];
}

@end

// The tab bar's controller holds no stack itself; the selected tab's sits among its parent's children.
void SGOpenModSettings(UIView *source) {
    UIViewController *owner = nil;
    for (UIResponder *r = source; r && !owner; r = r.nextResponder) {
        if ([r isKindOfClass:UIViewController.class]) owner = (UIViewController *)r;
    }
    UINavigationController *nav = nil;
    for (UIViewController *page = owner; page && !nav; page = page.parentViewController) nav = navigationIn(page);
    SGShowPage(nav.topViewController ?: SGTopController(), modSettingsPage());
}

// At the end of the settings list, or above the first row of the drawer's, with the inset for it
// added again whenever Spotify resets the inset.
static void placeRow(UICollectionView *list, SGModSettingsRow *row) {
    SGAdoptFonts(list, row);
    CGFloat bottom = list.contentSize.height;
    row.hidden = !row.drawer && bottom <= 0;
    row.frame = CGRectMake(0, row.drawer ? -kRowHeight : bottom, list.bounds.size.width, kRowHeight);

    UIEdgeInsets inset = list.contentInset;
    NSValue *applied = objc_getAssociatedObject(list, &kInsetKey);
    if (applied && UIEdgeInsetsEqualToEdgeInsets(inset, applied.UIEdgeInsetsValue)) return;
    if (row.drawer) inset.top += kRowHeight;
    else inset.bottom += kRowHeight;
    objc_setAssociatedObject(list, &kInsetKey, [NSValue valueWithUIEdgeInsets:inset], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    list.contentInset = inset;
}

// Media quality, Playback, Account and most of the rest of settings are the same controller class
// as the list they were opened from, which is why the row turned up at the end of all of them.
// What is on the navigation stack is not that controller though: every page in the app is wrapped
// in a MusicAppPageHostingViewController (trees/settings notifications opened.txt), and Spotify
// pushes a settings sub page as a page of its own, leaving the list it came from on the stack
// underneath. So the settings list inside the lowest wrapper that holds one is the list the row
// belongs at the end of, and a controller with no stack to be found on keeps the row rather than
// losing it.
static UIViewController *settingsListIn(UIViewController *page, Class kind) {
    if ([page isKindOfClass:kind]) return page;
    for (UIViewController *child in page.childViewControllers) {
        UIViewController *found = settingsListIn(child, kind);
        if (found) return found;
    }
    return nil;
}

static BOOL isSettingsRoot(UIViewController *list) {
    for (UIViewController *page in list.navigationController.viewControllers) {
        UIViewController *found = settingsListIn(page, list.class);
        if (found) return found == list;
    }
    return YES;
}

%hook _TtC21Settings_PlatformImpl26SettingsListViewController
- (void)viewDidLayoutSubviews {
    %orig;
    BOOL root = isSettingsRoot((UIViewController *)self);
    for (UIView *sub in ((UIViewController *)self).view.subviews) {
        if (![sub isKindOfClass:UICollectionView.class]) continue;
        SGModSettingsRow *row = objc_getAssociatedObject(sub, &kRowKey);
        // A page that laid itself out before it was on the stack looked like the list for as long
        // as that took; the row goes again as soon as it can be seen for what it is.
        if (!root) {
            [row removeFromSuperview];
            objc_setAssociatedObject(sub, &kRowKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            continue;
        }
        if (row) continue;
        row = [[SGModSettingsRow alloc] initWithFrame:CGRectZero];
        objc_setAssociatedObject(sub, &kRowKey, row, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [sub addSubview:row];
    }
}
%end

// The drawer's list (trees/test6.txt: SideDrawerListCollectionView under the profile header, Your
// plan its first cell) is one of several collection views on the page, so it is found by name.
%hook _TtC23SideDrawer_ListPageImpl18ListViewController
- (void)viewDidLayoutSubviews {
    %orig;
    SGForEachView(((UIViewController *)self).view, ^(UIView *v) {
        if (![v isKindOfClass:UICollectionView.class] || ![NSStringFromClass(v.class) containsString:@"SideDrawerListCollectionView"]) return;
        if (objc_getAssociatedObject(v, &kRowKey)) return;
        SGModSettingsRow *row = [[SGModSettingsRow alloc] initWithFrame:CGRectZero];
        row.drawer = YES;
        objc_setAssociatedObject(v, &kRowKey, row, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [v addSubview:row];
    });
}
%end

// The lists lay out after their controllers and again whenever their content changes.
%hook UICollectionView
- (void)layoutSubviews {
    %orig;
    SGModSettingsRow *row = objc_getAssociatedObject(self, &kRowKey);
    if (row) placeRow(self, row);
}
%end

%ctor {
    %init;
    SGRequireClasses(@[@"_TtC21Settings_PlatformImpl26SettingsListViewController", @"_TtC23SideDrawer_ListPageImpl18ListViewController"]);
    SGRegisterPages();
    SGCheckSigningOnce();
    SGWatchForUpdates();
}
