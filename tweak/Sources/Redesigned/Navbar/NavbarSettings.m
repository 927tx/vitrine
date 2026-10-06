#import "Core/SGCore.h"
#import "Settings/SGPage.h"
#import "Settings/SGPageStyle.h"
#import "Navbar.h"
#import "Shared/Navigation/AddTabSheet.h"

// What "Add a tab" offers: URIs Spotify's own router resolves to a page of its own, each with the
// name of the SPTEncoreIcon class method that draws its glyph. Playlists was spotify:collection:playlists
// until 0.20, which 9.1.78 knows only from its old iPad sidebar table and has no handler for (#66);
// spotify:playlists is the form its collection URI parser lists, next to spotify:playlists:by-you.
// The picker still asks the dispatcher about each one and leaves out what it has nowhere to send.
static NSArray<NSDictionary *> *tabPresets(void) {
    return @[
        @{SGTabTitle: @"Home", SGTabURI: @"spotify:home", SGTabIcon: @"home"},
        @{SGTabTitle: @"Search", SGTabURI: @"spotify:search", SGTabIcon: @"search"},
        @{SGTabTitle: @"Your Library", SGTabURI: @"spotify:collection", SGTabIcon: @"collection"},
        @{SGTabTitle: @"Liked Songs", SGTabURI: @"spotify:collection:tracks", SGTabIcon: @"heart"},
        @{SGTabTitle: @"Playlists", SGTabURI: @"spotify:playlists", SGTabIcon: @"playlist"},
        @{SGTabTitle: @"Albums", SGTabURI: @"spotify:collection:albums", SGTabIcon: @"album"},
        @{SGTabTitle: @"Artists", SGTabURI: @"spotify:collection:artists", SGTabIcon: @"artist"},
        @{SGTabTitle: @"Podcasts", SGTabURI: @"spotify:collection:podcasts", SGTabIcon: @"podcasts"},
        @{SGTabTitle: @"Audiobooks", SGTabURI: @"spotify:collection:audiobooks", SGTabIcon: @"audiobook"},
        @{SGTabTitle: @"Downloads", SGTabURI: @"spotify:collection:downloads", SGTabIcon: @"downloaded"},
        @{SGTabTitle: @"Your Episodes", SGTabURI: @"spotify:collection:your-episodes", SGTabIcon: @"bookmark"},
        @{SGTabTitle: @"Browse", SGTabURI: @"spotify:browse", SGTabIcon: @"browse"},
        @{SGTabTitle: @"New Releases", SGTabURI: @"spotify:new-releases", SGTabIcon: @"star"},
        @{SGTabTitle: @"Made For You", SGTabURI: @"spotify:made-for-you", SGTabIcon: @"user"},
        @{SGTabTitle: @"Concerts", SGTabURI: @"spotify:concerts", SGTabIcon: @"events"},
        @{SGTabTitle: @"Queue", SGTabURI: @"spotify:now-playing:queue", SGTabIcon: @"queue"},
        @{SGTabTitle: @"Create", SGTabURI: @"spotify:create-menu", SGTabIcon: @"plus"},
    ];
}

// The list the Navbar page edits: the saved order first, then every tab of Spotify's it does not
// name, in Spotify's order. Entries for tabs Spotify no longer has drop out.
static NSMutableArray<NSMutableDictionary *> *navbarEntries(void) {
    NSArray<NSString *> *stock = SGRNavbarStock();
    NSMutableArray<NSMutableDictionary *> *entries = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSDictionary *entry in SGRNavbarLayout()) {
        NSString *ident = entry[SGRNavbarID];
        if (![ident isKindOfClass:NSString.class] || [seen containsObject:ident]) continue;
        if (!entry[SGRNavbarURI] && ![stock containsObject:ident]) continue;
        [seen addObject:ident];
        [entries addObject:[entry mutableCopy]];
    }
    for (NSString *ident in stock) {
        if ([seen containsObject:ident]) continue;
        [entries addObject:[@{SGRNavbarID: ident, SGRNavbarTitle: ident} mutableCopy]];
    }
    return entries;
}

// A tab of the mod's own carries an identity of its own, so the same page can sit on the bar twice
// and renaming one does not shuffle the order.
static void appendTab(NSDictionary *tab) {
    NSMutableDictionary *entry = [@{SGRNavbarID: NSUUID.UUID.UUIDString, SGRNavbarTitle: tab[SGTabTitle],
                                    SGRNavbarURI: tab[SGTabURI], SGRNavbarIcon: tab[SGTabIcon]} mutableCopy];
    entry[SGRNavbarIconSet] = tab[SGTabIconSet];
    SGRSetNavbarLayout([navbarEntries() arrayByAddingObject:entry]);
    SGRRefreshTabBar();
}

// Split tabs: a switch per tab of the bar, on to set it apart at the trailing end.
@interface SGRSplitTabsPage : SGPage
@end

@implementation SGRSplitTabsPage {
    NSArray<NSDictionary *> *_entries;
    NSMutableSet<NSString *> *_split;
    UIView *_intro;
}

- (instancetype)init {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    self.title = @"Split Tabs";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _intro = SGNote(@"Tabs switched on here sit apart from the others at the right end of the bar, the way the Music "
                    "app sets Search apart. Hidden tabs stay hidden.");
    self.tableView.tableHeaderView = _intro;
    _entries = navbarEntries();
    _split = [NSMutableSet setWithArray:SGRNavbarSplit()];
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    SGFitNote(self.tableView, _intro, 24, 0);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    SGInsetForBars(self.tableView);
}

- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)_entries.count;
}

- (UIView *)tableView:(UITableView *)table viewForHeaderInSection:(NSInteger)section {
    return SGSectionHeader(table, @"Tabs");
}

- (CGFloat)tableView:(UITableView *)table heightForHeaderInSection:(NSInteger)section {
    return SGSectionHeaderHeight;
}

- (CGFloat)tableView:(UITableView *)table heightForFooterInSection:(NSInteger)section {
    return CGFLOAT_MIN;
}

- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = SGDequeueCell(table, @"split");
    NSDictionary *entry = _entries[(NSUInteger)path.row];
    BOOL apart = [_split containsObject:entry[SGRNavbarID]];
    NSString *where = [entry[SGRNavbarHidden] boolValue] ? @"Hidden" : apart ? @"Apart, on the right" : @"With the others";
    SGFillCell(cell, entry[SGRNavbarTitle], where, nil, nil);
    UISwitch *toggle = [UISwitch new];
    toggle.onTintColor = SGGreen();
    toggle.on = apart;
    toggle.tag = path.row;
    [toggle addTarget:self action:@selector(toggled:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    return cell;
}

- (void)toggled:(UISwitch *)toggle {
    NSString *ident = _entries[(NSUInteger)toggle.tag][SGRNavbarID];
    if (toggle.on) [_split addObject:ident];
    else [_split removeObject:ident];
    SGRSetNavbarSplit(_split.allObjects);
    SGRRefreshTabBar();
    [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:toggle.tag inSection:0]] withRowAnimation:UITableViewRowAnimationNone];
}

@end

typedef NS_ENUM(NSInteger, SGRNavbarSection) {
    SGRNavbarSectionSwitch,
    SGRNavbarSectionTabs,
    SGRNavbarSectionAdd,
    SGRNavbarSectionSplit,
    SGRNavbarSectionReset,
    SGRNavbarSectionCount,
};

static NSString *switchKey(NSInteger row) {
    return row == 2 ? SGRKeyNavbarMinimize : row == 1 ? SGRKeyNavbarHideLabels : SGRKeyNavbar;
}

// The tabs, in the order the bar shows them: drag to reorder, tap to show or hide, swipe a tab of
// your own away. Spotify's own tabs can only be hidden, never removed. Mod Settings and the welcome
// tour show the same editor.
@interface SGRNavbarPage : SGPage
@end

@implementation SGRNavbarPage {
    NSMutableArray<NSMutableDictionary *> *_entries;
    UIView *_intro;
}

- (instancetype)init {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    self.title = @"Navbar";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.allowsSelectionDuringEditing = YES;
    self.tableView.editing = YES;
    _intro = SGNote(@"Drag to reorder, tap to show or hide.");
    self.tableView.tableHeaderView = _intro;
    _entries = navbarEntries();
}

- (void)reload {
    _entries = navbarEntries();
    [self.tableView reloadData];
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    SGFitNote(self.tableView, _intro, 24, 0);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    SGInsetForBars(self.tableView);
}

- (void)save {
    SGRSetNavbarLayout(_entries);
    // A split tab swiped away leaves the split list with it.
    NSArray *idents = [_entries valueForKey:SGRNavbarID];
    SGRSetNavbarSplit([SGRNavbarSplit() filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF IN %@", idents]]);
    SGRRefreshTabBar();
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)table {
    return SGRNavbarSectionCount;
}

- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    if (section == SGRNavbarSectionSwitch) return 3;
    return section == SGRNavbarSectionTabs ? (NSInteger)_entries.count : 1;
}

- (NSString *)headerFor:(NSInteger)section {
    return section == SGRNavbarSectionTabs ? @"Tabs" : nil;
}

- (UIView *)tableView:(UITableView *)table viewForHeaderInSection:(NSInteger)section {
    NSString *title = [self headerFor:section];
    return title ? SGSectionHeader(table, title) : nil;
}

- (CGFloat)tableView:(UITableView *)table heightForHeaderInSection:(NSInteger)section {
    if ([self headerFor:section]) return SGSectionHeaderHeight;
    return [self tableView:table numberOfRowsInSection:section] ? SGSectionGap : CGFLOAT_MIN;
}

- (CGFloat)tableView:(UITableView *)table heightForFooterInSection:(NSInteger)section {
    return CGFLOAT_MIN;
}

- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = SGDequeueCell(table, @"navbar");
    switch (path.section) {
        case SGRNavbarSectionSwitch: {
            static NSString *const titles[] = {@"Custom navbar", @"Hide labels", @"Minimize on scroll"};
            static NSString *const subtitles[] = {nil, @"Icons only", @"Two tabs and the now playing bar in one row as a page scrolls down"};
            SGFillCell(cell, titles[path.row], subtitles[path.row], nil, nil);
            UISwitch *toggle = [UISwitch new];
            toggle.onTintColor = SGGreen();
            toggle.tag = path.row;
            toggle.on = path.row == 1 ? SGHidden(SGRKeyNavbarHideLabels) : SGEnabled(switchKey(path.row));
            [toggle addTarget:self action:@selector(toggled:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
            break;
        }
        case SGRNavbarSectionTabs: {
            NSDictionary *entry = _entries[(NSUInteger)path.row];
            BOOL hidden = [entry[SGRNavbarHidden] boolValue];
            NSString *uri = entry[SGRNavbarURI];
            SGFillCell(cell, entry[SGRNavbarTitle], hidden ? @"Hidden" : (uri ?: @"Spotify's own tab"),
                     hidden ? SGGrey() : nil, hidden ? @"eye.slash" : @"eye");
            break;
        }
        case SGRNavbarSectionAdd:
            SGFillCell(cell, @"Add a tab…", nil, nil, @"plus");
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            break;
        case SGRNavbarSectionSplit:
            SGFillCell(cell, @"Split tabs", @"Place chosen tabs apart on the right", nil, @"rectangle.split.2x1");
            cell.accessoryView = SGSymbolView(@"chevron.right", 13, UIImageSymbolWeightSemibold, 16);
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            break;
        default:
            SGFillCell(cell, @"Use Spotify's order", nil, nil, @"arrow.uturn.backward");
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            break;
    }
    return cell;
}

- (BOOL)tableView:(UITableView *)table canMoveRowAtIndexPath:(NSIndexPath *)path {
    return path.section == SGRNavbarSectionTabs;
}

- (BOOL)tableView:(UITableView *)table canEditRowAtIndexPath:(NSIndexPath *)path {
    return path.section == SGRNavbarSectionTabs;
}

// Spotify's own tabs stay on the list to be switched back on; only the mod's own can go.
- (UITableViewCellEditingStyle)tableView:(UITableView *)table editingStyleForRowAtIndexPath:(NSIndexPath *)path {
    if (path.section != SGRNavbarSectionTabs) return UITableViewCellEditingStyleNone;
    return _entries[(NSUInteger)path.row][SGRNavbarURI] ? UITableViewCellEditingStyleDelete : UITableViewCellEditingStyleNone;
}

- (NSIndexPath *)tableView:(UITableView *)table targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)from toProposedIndexPath:(NSIndexPath *)to {
    return to.section == SGRNavbarSectionTabs ? to : from;
}

- (void)tableView:(UITableView *)table moveRowAtIndexPath:(NSIndexPath *)from toIndexPath:(NSIndexPath *)to {
    NSMutableDictionary *entry = _entries[(NSUInteger)from.row];
    [_entries removeObjectAtIndex:(NSUInteger)from.row];
    [_entries insertObject:entry atIndex:(NSUInteger)to.row];
    [self save];
}

- (void)tableView:(UITableView *)table commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)path {
    if (style != UITableViewCellEditingStyleDelete) return;
    [_entries removeObjectAtIndex:(NSUInteger)path.row];
    [self save];
    [table deleteRowsAtIndexPaths:@[path] withRowAnimation:UITableViewRowAnimationAutomatic];
}

- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    if (path.section == SGRNavbarSectionTabs) {
        NSMutableDictionary *entry = _entries[(NSUInteger)path.row];
        entry[SGRNavbarHidden] = [entry[SGRNavbarHidden] boolValue] ? nil : @YES;
        [self save];
        [table reloadRowsAtIndexPaths:@[path] withRowAnimation:UITableViewRowAnimationNone];
    } else if (path.section == SGRNavbarSectionAdd) {
        __weak typeof(self) weakSelf = self;
        SGPresentAddTabSheet(self, tabPresets(), ^(NSDictionary *tab) {
            appendTab(tab);
            [weakSelf reload];
        });
    } else if (path.section == SGRNavbarSectionSplit) {
        [self.navigationController pushViewController:[SGRSplitTabsPage new] animated:YES];
    } else if (path.section == SGRNavbarSectionReset) {
        [self reset];
    }
}

- (void)toggled:(UISwitch *)toggle {
    SGSetEnabled(switchKey(toggle.tag), toggle.on);
    if (!toggle.on && toggle.tag == 2) SGRSetTabBarMinimized(NO, NO);
    SGRRefreshTabBar();
}

- (void)reset {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Use Spotify's order"
                                                                  message:@"Every tab of Spotify's comes back where Spotify put it, the tabs you added go, and no tab is split apart."
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        SGRSetNavbarLayout(@[]);
        SGRSetNavbarSplit(@[]);
        SGRRefreshTabBar();
        self->_entries = navbarEntries();
        [self.tableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

UIViewController *SGRNavbarSettingsPage(void) {
    return [SGRNavbarPage new];
}

UIViewController *SGRNavbarEditorPage(void) {
    return [SGRNavbarPage new];
}
