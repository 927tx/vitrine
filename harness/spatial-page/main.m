// The Sing page (Shared/Sing/SingSettings.m) and the Spatial voice page under it, with its preview
// (SGSpatialPreview.m), on the real Settings/ framework; stubs.m stands in for Sing's state and plays the head's
// motion. The launch line sets things up and then plays actions, one every 0.7 s from 1 s in; screenshot after.
//
//     ./build.sh && xcrun simctl install <udid> build/SpatialPageHarness.app
//     xcrun simctl launch <udid> com.vojta.spatialpageharness [setup...] [action...]
//
// Setup: keep (the stored Sing keys stay; otherwise they are cleared first), on (spatial voice on), allowed or
// denied (what Motion & Fitness answers; unasked otherwise, so the preview never listens), head=sweep (the head
// turning 45 degrees each way every 6 s), head=<degrees> (still, then turned that far left at 2 s and held), width=<points>
// (the window that narrow, centred), slow (animations at a tenth of their speed).
// Actions: spatial (the Spatial voice row tapped), toggle=<section>.<row> (that row's switch flipped the way a tap
// does), pop, dump (the rows, the header's height and what VoiceOver reads on the preview, to the log).
#import <CoreMotion/CoreMotion.h>
#import <UIKit/UIKit.h>
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Shared/Sing/Sing.h"

extern CMAuthorizationStatus sg_motionAllowed;
extern double (^sg_headYaw)(double seconds);

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
    NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
    NSUserDefaults *store = NSUserDefaults.standardUserDefaults;
    if (![args containsObject:@"keep"]) {
        for (NSString *key in store.dictionaryRepresentation.allKeys) {
            if ([key hasPrefix:@"spotifyglass.sing"]) [store removeObjectForKey:key];
        }
    }
    CGFloat width = 0;
    NSMutableArray<NSString *> *actions = [NSMutableArray array];
    for (NSString *arg in [args subarrayWithRange:NSMakeRange(1, args.count - 1)]) {
        if ([arg isEqualToString:@"on"]) SGSetEnabled(SGKeySingSpatial, YES);
        else if ([arg isEqualToString:@"allowed"]) sg_motionAllowed = CMAuthorizationStatusAuthorized;
        else if ([arg isEqualToString:@"denied"]) sg_motionAllowed = CMAuthorizationStatusDenied;
        else if ([arg isEqualToString:@"head=sweep"]) sg_headYaw = ^double(double t) { return M_PI_4 * sin(2 * M_PI * t / 6); };
        else if ([arg hasPrefix:@"head="]) {
            double turn = [arg substringFromIndex:5].doubleValue * M_PI / 180;
            sg_headYaw = ^double(double t) {
                double s = fmin(1, fmax(0, (t - 2) / 0.6));
                return turn * s * s * (3 - 2 * s);
            };
        } else if ([arg hasPrefix:@"width="]) width = [arg substringFromIndex:6].doubleValue;
        else if (![@[@"keep", @"slow", @"on"] containsObject:arg]) [actions addObject:arg];
    }

    CGRect screen = UIScreen.mainScreen.bounds;
    self.window = [[UIWindow alloc] initWithFrame:width > 0 ? CGRectMake((screen.size.width - width) / 2, 0, width, screen.size.height) : screen];
    self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.nav = [[UINavigationController alloc] initWithRootViewController:SGSingSettingsPage()];
    self.window.rootViewController = self.nav;
    [self.window makeKeyAndVisible];
    if ([args containsObject:@"slow"]) self.window.layer.speed = 0.1;

    [actions enumerateObjectsUsingBlock:^(NSString *action, NSUInteger i, BOOL *stop) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((1 + 0.7 * i) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSLog(@"[harness] %@", action);
            [self run:action];
        });
    }];
    return YES;
}

- (UITableView *)table {
    return ((UITableViewController *)self.nav.topViewController).tableView;
}

- (void)run:(NSString *)action {
    NSArray<NSString *> *parts = [action componentsSeparatedByString:@"="];
    NSString *verb = parts.firstObject, *value = parts.count > 1 ? parts[1] : @"";
    UITableView *table = self.table;
    if ([verb isEqualToString:@"spatial"]) {
        [table.delegate tableView:table didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:3 inSection:0]];
    } else if ([verb isEqualToString:@"toggle"]) {
        NSArray<NSString *> *at = [value componentsSeparatedByString:@"."];
        UITableViewCell *cell = [table cellForRowAtIndexPath:[NSIndexPath indexPathForRow:at[1].integerValue inSection:at[0].integerValue]];
        NSMutableArray<UISwitch *> *switches = [NSMutableArray array];
        findViews(cell, UISwitch.class, switches);
        UISwitch *toggle = switches.firstObject;
        [toggle setOn:!toggle.on animated:YES];
        [toggle sendActionsForControlEvents:UIControlEventValueChanged];
    } else if ([verb isEqualToString:@"pop"]) {
        [self.nav popViewControllerAnimated:YES];
    } else if ([verb isEqualToString:@"dump"]) {
        UIView *header = table.tableHeaderView;
        NSLog(@"[harness] header %@ %.0fx%.0f; VoiceOver reads \"%@\", \"%@\"", NSStringFromClass(header.class), header.bounds.size.width,
              header.bounds.size.height, header.accessibilityLabel, header.accessibilityValue);
        for (NSInteger section = 0; section < table.numberOfSections; section++) {
            NSMutableArray<NSString *> *rows = [NSMutableArray array];
            for (NSInteger row = 0; row < [table numberOfRowsInSection:section]; row++) {
                UITableViewCell *cell = [table cellForRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:section]];
                NSMutableArray<UILabel *> *labels = [NSMutableArray array];
                findViews(cell.contentView, UILabel.class, labels);
                NSMutableArray<NSString *> *texts = [NSMutableArray array];
                for (UILabel *label in labels) if (label.text.length) [texts addObject:label.text];
                [rows addObject:[texts componentsJoinedByString:@" / "]];
            }
            NSLog(@"[harness] section %ld: %@", (long)section, [rows componentsJoinedByString:@", "]);
        }
    }
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        // The redesign's look: black, the redesign's own accent.
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:SGKeyRedesign];
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(AppDelegate.class));
    }
}
