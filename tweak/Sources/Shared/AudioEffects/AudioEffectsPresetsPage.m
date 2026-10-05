// The Presets and Headphones pages the Audio effects page's first card opens. Both stay open after a pick,
// so one preset or one headphone after another can be heard before going back.
#import "Core/SGCore.h"
#import "Settings/SGPage.h"
#import "Settings/SGPageStyle.h"
#import "AudioEffectsPage.h"
#import "AudioEffectsPresets.h"

static void showAlert(UIViewController *owner, NSString *title, NSString *message) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [owner presentViewController:alert animated:YES completion:nil];
}

static void tick(UITableViewCell *cell, BOOL on) {
    if (on) {
        UIImageView *tick = SGSymbolView(@"checkmark", 13, UIImageSymbolWeightSemibold, 16);
        tick.tintColor = SGGreen();
        cell.accessoryView = tick;
    }
    cell.accessibilityTraits = on ? UIAccessibilityTraitButton | UIAccessibilityTraitSelected : UIAccessibilityTraitButton;
}

#pragma mark - presets

// A pick replaces every effect's settings, so the first pick each time the page opens saves them first,
// as one of the user's presets under this name, kept at the top of theirs: a tap on it puts them back.
static NSString *const kBeforePresets = @"Before presets";

// The user's presets, the settings from before the last round of picks first.
static NSArray<NSString *> *userPresetNames(void) {
    NSMutableArray<NSString *> *names = [SGDSPUserPresetNames() mutableCopy];
    if ([names containsObject:kBeforePresets]) {
        [names removeObject:kBeforePresets];
        [names insertObject:kBeforePresets atIndex:0];
    }
    return names;
}

// The built-in presets, then the user's, then Save. The last one picked is ticked until something else is.
@interface SGDSPPresetList : SGPage
@end

@implementation SGDSPPresetList {
    NSArray<NSString *> *_builtIn, *_mine;
    NSIndexPath *_picked;
    UIView *_footer;
    BOOL _kept;   // the settings from before this page's first pick are saved
}

- (instancetype)init {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    self.title = @"Presets";
    _builtIn = SGDSPBuiltInPresetNames();
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _footer = SGNote(@"Picking a preset turns Audio effects on and replaces the other effects' settings. A built-in "
                      "preset leaves the Graphic EQ, your headphones' correction, as it is; your own presets keep every "
                      "effect, the Graphic EQ too. What you had before the first pick is kept under Yours as Before presets. "
                      "Swipe left on one of yours to delete it.");
    self.tableView.tableFooterView = _footer;
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    SGFitNote(self.tableView, _footer, 16, 24);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    SGInsetForBars(self.tableView);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    _mine = userPresetNames();
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)table {
    return 3;
}

- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return (NSInteger)_builtIn.count;
    if (section == 1) return MAX((NSInteger)_mine.count, 1);
    return 1;
}

- (UIView *)tableView:(UITableView *)table viewForHeaderInSection:(NSInteger)section {
    return section == 2 ? nil : SGSectionHeader(table, section == 0 ? @"Built in" : @"Yours");
}

- (CGFloat)tableView:(UITableView *)table heightForHeaderInSection:(NSInteger)section {
    return section == 2 ? SGSectionGap : SGSectionHeaderHeight;
}

- (UIView *)tableView:(UITableView *)table viewForFooterInSection:(NSInteger)section {
    return nil;
}

- (CGFloat)tableView:(UITableView *)table heightForFooterInSection:(NSInteger)section {
    return CGFLOAT_MIN;
}

- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = SGDequeueCell(table, @"preset");
    if (path.section == 2) {
        SGFillCell(cell, @"Save current settings…", @"Every effect as it is now, under a name", nil, @"square.and.arrow.down");
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        return cell;
    }
    if (path.section == 1 && !_mine.count) {
        SGFillCell(cell, @"None saved yet", nil, SGGrey(), nil);
        cell.accessibilityTraits = UIAccessibilityTraitNone;
        return cell;
    }
    BOOL builtIn = path.section == 0;
    SGFillCell(cell, (builtIn ? _builtIn : _mine)[(NSUInteger)path.row], builtIn ? SGDSPBuiltInPresetDetail(path.row) : nil, nil, nil);
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    tick(cell, [path isEqual:_picked]);
    return cell;
}

- (BOOL)tableView:(UITableView *)table shouldHighlightRowAtIndexPath:(NSIndexPath *)path {
    return path.section != 1 || _mine.count;
}

- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    if (path.section == 2) {
        [self askForName];
        return;
    }
    if (path.section == 1 && !_mine.count) return;
    NSString *name = path.section == 1 ? _mine[(NSUInteger)path.row] : nil;
    // Loading Before presets itself is the way back, so it is never written over by its own pick.
    if (!_kept && ![name isEqualToString:kBeforePresets]) {
        SGDSPSaveUserPreset(kBeforePresets);
        _kept = YES;
        _mine = userPresetNames();
    }
    if (path.section == 0) SGDSPLoadBuiltInPreset(path.row);
    else if (!SGDSPLoadUserPreset(name)) return;
    _picked = name ? [NSIndexPath indexPathForRow:(NSInteger)[_mine indexOfObject:name] inSection:1] : path;
    [table reloadSections:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, 2)] withRowAnimation:UITableViewRowAnimationNone];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)table trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)path {
    if (path.section != 1 || !_mine.count) return nil;
    NSString *name = _mine[(NSUInteger)path.row];
    UIContextualAction *delete = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Delete"
        handler:^(UIContextualAction *action, UIView *view, void (^done)(BOOL)) {
            SGDSPDeleteUserPreset(name);
            self->_mine = userPresetNames();
            NSIndexPath *picked = self->_picked;
            if (picked.section == 1 && picked.row == path.row) self->_picked = nil;
            else if (picked.section == 1 && picked.row > path.row) self->_picked = [NSIndexPath indexPathForRow:picked.row - 1 inSection:1];
            // The rows under it close up; the last one gives way to the placeholder instead.
            if (self->_mine.count) [self.tableView deleteRowsAtIndexPaths:@[path] withRowAnimation:UITableViewRowAnimationAutomatic];
            else [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:1] withRowAnimation:UITableViewRowAnimationFade];
            done(YES);
        }];
    delete.image = [UIImage systemImageNamed:@"trash"];
    return [UISwipeActionsConfiguration configurationWithActions:@[delete]];
}

- (void)askForName {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Save preset"
        message:@"A preset of the same name is replaced." preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Name";
        field.autocapitalizationType = UITextAutocapitalizationTypeSentences;
        field.keyboardAppearance = UIKeyboardAppearanceDark;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *name = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!name.length) return;
        SGDSPSaveUserPreset(name);
        self->_mine = userPresetNames();
        self->_picked = [NSIndexPath indexPathForRow:(NSInteger)[self->_mine indexOfObject:name] inSection:1];
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, 2)] withRowAnimation:UITableViewRowAnimationFade];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

UIViewController *SGDSPPresetsPage(void) {
    return [SGDSPPresetList new];
}

#pragma mark - headphones

// AutoEq's headphones under a search field, the one in use ticked, with None above them. A tap downloads its
// GraphicEQ and turns the Graphic EQ on with it; None turns it off again. Pulling down fetches the list again.
@interface SGDSPHeadphoneList : SGPage <UISearchBarDelegate>
@end

@implementation SGDSPHeadphoneList {
    NSArray<SGAutoEqHeadphone *> *_all, *_shown;
    NSString *_message;          // loading, or why the list did not come
    BOOL _failed;
    NSString *_applying;         // the path being downloaded
    UISearchBar *_search;
    UIView *_header, *_footer;
}

- (instancetype)init {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    self.title = @"Headphones";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    UITableView *table = self.tableView;
    table.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    _search = [UISearchBar new];
    _search.placeholder = @"Search headphones";
    _search.searchBarStyle = UISearchBarStyleMinimal;
    _search.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    _search.keyboardAppearance = UIKeyboardAppearanceDark;
    _search.delegate = self;
    _header = SGNote(@"Corrections that make your headphones sound neutral, measured by AutoEq. Picking one turns Audio effects and the Graphic EQ on with it.");
    [_header addSubview:_search];
    table.tableHeaderView = _header;
    _footer = SGNote(@"From AutoEq by Jaakko Pasanen, MIT License. Pull down to fetch the list again.");
    table.tableFooterView = _footer;
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(refresh) forControlEvents:UIControlEventValueChanged];
    [self load:NO];
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    _search.frame = CGRectMake(8, 4, self.tableView.bounds.size.width - 16, 44);
    SGFitNote(self.tableView, _header, 52, 8);
    SGFitNote(self.tableView, _footer, 16, 24);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    SGInsetForBars(self.tableView);
}

- (void)refresh {
    [self load:YES];
}

- (void)load:(BOOL)refresh {
    if (!_all) _message = @"Loading AutoEq's list…";
    _failed = NO;
    [self.tableView reloadData];
    SGAutoEqLoadIndex(refresh, ^(NSArray<SGAutoEqHeadphone *> *headphones, NSString *error) {
        [self.refreshControl endRefreshing];
        if (headphones) self->_all = headphones;
        self->_failed = error != nil;
        self->_message = error ? [NSString stringWithFormat:@"%@. Tap to try again.", error] : nil;
        [self filter];
    });
}

- (void)filter {
    _shown = SGAutoEqSearch(_all ?: @[], _search.text);
    [self.tableView reloadData];
}

- (void)searchBar:(UISearchBar *)bar textDidChange:(NSString *)text {
    [self filter];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)bar {
    [bar resignFirstResponder];
}

// Whether a headphone's correction is what the Graphic EQ plays, rather than nothing or the user's own curve.
static BOOL headphoneInUse(void) {
    return SGDSPSwitch(SGKeyDSPGraphicEq) && SGDSPString(SGKeyDSPGraphicEqHeadphone).length;
}

// Sections: the loading or error message, None, the headphones.
- (NSInteger)numberOfSectionsInTableView:(UITableView *)table {
    return 3;
}

- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return _message ? 1 : 0;
    if (section == 1) return 1;
    return _all && !_shown.count && _search.text.length ? 1 : (NSInteger)_shown.count;
}

- (UIView *)tableView:(UITableView *)table viewForHeaderInSection:(NSInteger)section {
    return nil;
}

- (CGFloat)tableView:(UITableView *)table heightForHeaderInSection:(NSInteger)section {
    return section == 0 && !_message ? CGFLOAT_MIN : SGSectionGap;
}

- (UIView *)tableView:(UITableView *)table viewForFooterInSection:(NSInteger)section {
    return nil;
}

- (CGFloat)tableView:(UITableView *)table heightForFooterInSection:(NSInteger)section {
    return CGFLOAT_MIN;
}

- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = SGDequeueCell(table, @"headphone");
    if (path.section == 0) {
        SGFillCell(cell, _message, nil, _failed ? SGRed() : SGGrey(), _failed ? @"exclamationmark.triangle.fill" : nil);
        cell.selectionStyle = _failed ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
        return cell;
    }
    cell.accessibilityValue = nil;
    if (path.section == 1) {
        SGFillCell(cell, @"None", nil, nil, nil);
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        tick(cell, !headphoneInUse());
        return cell;
    }
    if (!_shown.count) {
        SGFillCell(cell, @"No headphones match", nil, SGGrey(), nil);
        cell.accessibilityTraits = UIAccessibilityTraitNone;
        return cell;
    }
    SGAutoEqHeadphone *headphone = _shown[(NSUInteger)path.row];
    SGFillCell(cell, headphone.name, headphone.source, nil, nil);
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    if ([headphone.path isEqualToString:_applying]) {
        UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        spinner.color = SGGrey();
        spinner.accessibilityLabel = @"Applying";
        [spinner startAnimating];
        cell.accessoryView = spinner;
        // The cell is what VoiceOver reads, not the spinner in it.
        cell.accessibilityValue = @"Applying";
        return cell;
    }
    tick(cell, headphoneInUse() && [headphone.path isEqualToString:SGDSPString(SGKeyDSPGraphicEqHeadphone)]);
    return cell;
}

- (BOOL)tableView:(UITableView *)table shouldHighlightRowAtIndexPath:(NSIndexPath *)path {
    if (path.section == 0) return _failed;
    return (path.section == 1 || _shown.count > 0) && !_applying;
}

- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    if (path.section == 0) {
        if (_failed) [self load:YES];
        return;
    }
    if (_applying) return;
    if (path.section == 1) {
        // Only a headphone's correction is taken off: a curve of the user's own, with no headphone, stays.
        if (!headphoneInUse()) return;
        SGDSPSetString(SGKeyDSPGraphicEqHeadphone, @"");
        SGDSPSetSwitch(SGKeyDSPGraphicEq, NO);
        [table reloadData];
        return;
    }
    if (!_shown.count) return;
    SGAutoEqHeadphone *headphone = _shown[(NSUInteger)path.row];
    _applying = headphone.path;
    [table reloadData];
    SGAutoEqApply(headphone, ^(NSString *error) {
        self->_applying = nil;
        [self.tableView reloadData];
        if (error) showAlert(self, [NSString stringWithFormat:@"Could not apply %@", headphone.name], error);
    });
}

@end

UIViewController *SGDSPHeadphonesPage(void) {
    return [SGDSPHeadphoneList new];
}

NSString *SGDSPHeadphoneSummary(void) {
    NSString *path = SGDSPString(SGKeyDSPGraphicEqHeadphone);
    return path.length && SGDSPSwitch(SGKeyDSPGraphicEq) ? SGAutoEqNameOf(path) : @"None";
}
