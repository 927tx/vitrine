// Mod Settings' main page as App/ModSettings.x builds it, opened the way holding Home opens it
// (SGOpenModSettings), with the real App/Pages.m behind its Redesigned UI switch and the real Settings/
// framework; stubs.m stands in for every page a row opens. The launch line sets the look up and then plays
// actions, one every 0.9 s from 1 s in; screenshot after.
//
//     THEOS=$HOME/theos ./build.sh && xcrun simctl install <udid> build/ModSettingsHarness.app
//     xcrun simctl launch <udid> com.vitrine.modsettingsharness [setup...] [action...]
//
// Setup: redesign (Redesigned UI stored on), warning (a red environment row at the top), keep (the stored
// look stays; otherwise it is cleared first).
// Actions: toggle=<section>.<row> (that row's switch flipped the way a tap does), cancel (the alert that
// switch brings up closed with Later), bottom (scrolled to the end), dump (the rows of each section and
// what each reads beside its chevron, to the log).
#import <UIKit/UIKit.h>
#import "Core/SGCore.h"
#import "Settings/SGPage.h"
#import "Settings/SGModPage.h"

// Spotify's page protocol, so SGRegisterPages finds one and the page is pushed as on the phone.
@protocol SPTPageController <NSObject>
@end

BOOL SGHarnessWarning;

static void findViews(UIView *root, Class kind, NSMutableArray *found) {
    if ([root isKindOfClass:kind]) [found addObject:root];
    for (UIView *sub in root.subviews) findViews(sub, kind, found);
}

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UINavigationController *nav;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    NSLog(@"[harness] page protocol %@", NSStringFromProtocol(@protocol(SPTPageController)));
    NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
    if (![args containsObject:@"keep"]) {
        SGSetEnabled(SGKeyRedesign, NO);
        SGSetEnabled(SGKeyRedesignUntested, NO);
    }
    NSMutableArray<NSString *> *actions = [NSMutableArray array];
    for (NSString *arg in [args subarrayWithRange:NSMakeRange(1, args.count - 1)]) {
        if ([arg isEqualToString:@"redesign"]) SGSetEnabled(SGKeyRedesign, YES);
        else if ([arg isEqualToString:@"warning"]) SGHarnessWarning = YES;
        else if (![arg isEqualToString:@"keep"]) [actions addObject:arg];
    }

    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    UIViewController *home = [UIViewController new];
    home.view.backgroundColor = UIColor.blackColor;
    self.nav = [[UINavigationController alloc] initWithRootViewController:home];
    self.window.rootViewController = self.nav;
    [self.window makeKeyAndVisible];
    dispatch_async(dispatch_get_main_queue(), ^{ SGOpenModSettings(home.view); });

    [actions enumerateObjectsUsingBlock:^(NSString *action, NSUInteger i, BOOL *stop) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((1 + 0.9 * i) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSLog(@"[harness] %@", action);
            [self run:action];
        });
    }];
    return YES;
}

- (UITableView *)table {
    return ((UITableViewController *)self.nav.topViewController).tableView;
}

- (NSIndexPath *)pathFrom:(NSString *)text {
    NSArray<NSString *> *at = [text componentsSeparatedByString:@"."];
    return [NSIndexPath indexPathForRow:at[1].integerValue inSection:at[0].integerValue];
}

- (void)run:(NSString *)action {
    NSArray<NSString *> *parts = [action componentsSeparatedByString:@"="];
    NSString *verb = parts.firstObject, *value = parts.count > 1 ? parts[1] : @"";
    UITableView *table = self.table;
    if ([verb isEqualToString:@"toggle"]) {
        NSMutableArray<UIControl *> *controls = [NSMutableArray array];
        findViews([table cellForRowAtIndexPath:[self pathFrom:value]].accessoryView, UIControl.class, controls);
        UIControl *toggle = nil;
        for (UIControl *control in controls) if ([control respondsToSelector:@selector(setOn:animated:)]) toggle = control;
        if (!toggle) { NSLog(@"[harness] no switch at %@", value); return; }
        [(id)toggle setOn:![(id)toggle isOn] animated:YES];
        [toggle sendActionsForControlEvents:UIControlEventValueChanged];
    } else if ([verb isEqualToString:@"cancel"]) {
        UIAlertController *alert = (UIAlertController *)self.nav.presentedViewController;
        if (![alert isKindOfClass:UIAlertController.class]) return;
        NSLog(@"[harness] alert \"%@\": %@", alert.title, alert.message);
        [alert dismissViewControllerAnimated:YES completion:nil];
    } else if ([verb isEqualToString:@"bottom"]) {
        [table setContentOffset:CGPointMake(0, MAX(-table.adjustedContentInset.top, table.contentSize.height - table.bounds.size.height + table.adjustedContentInset.bottom)) animated:NO];
    } else if ([verb isEqualToString:@"dump"]) {
        NSLog(@"[harness] Redesigned UI stored %d", SGRedesignedUIStored());
        for (NSInteger section = 0; section < table.numberOfSections; section++) {
            NSMutableArray<NSString *> *rows = [NSMutableArray array];
            for (NSInteger row = 0; row < [table numberOfRowsInSection:section]; row++) {
                NSIndexPath *path = [NSIndexPath indexPathForRow:row inSection:section];
                UITableViewCell *cell = [table.dataSource tableView:table cellForRowAtIndexPath:path];
                NSMutableArray<UILabel *> *labels = [NSMutableArray array];
                findViews(cell.accessoryView, UILabel.class, labels);
                NSString *text = [(UIListContentConfiguration *)cell.contentConfiguration text];
                [rows addObject:labels.count ? [NSString stringWithFormat:@"%@ [%@]", text, labels.firstObject.text] : text];
            }
            NSLog(@"[harness] section %ld: %@", (long)section, [rows componentsJoinedByString:@", "]);
        }
    }
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(AppDelegate.class));
    }
}
