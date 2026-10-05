// AirPods gestures in the simulator: the real HeadGestures.x (through Logos), its settings page and the
// detector, with Spotify's player and collection platform stood in for, and CMHeadphoneMotionManager's
// start and stop taken over so the harness hands the handler made-up motion on the manager's own queue.
// The simulator has no headphones, so this proves the wiring (the switch, playing or not, the thresholds,
// the like and skip calls, the learning alerts), not the motion. A fixed run of steps, one every second;
// each check logs "ok" or "FAIL" and the last line says how many failed.
//
//     THEOS=$HOME/theos ./build.sh && xcrun simctl install <udid> ../build/sim/HeadGesturesSim.app
//     xcrun simctl launch --console-pty <udid> com.vitrine.headgesturessim
#import <UIKit/UIKit.h>
#import <CoreMotion/CoreMotion.h>
#import <objc/runtime.h>
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Shared/HeadGestures/HeadGestures.h"
#import "Shared/Player/PlayerState.h"

static int failures;
static void check(BOOL ok, NSString *what) {
    if (!ok) failures++;
    NSLog(@"[harness] %@ %@", ok ? @"ok  " : @"FAIL", what);
}

#pragma mark - Spotify stood in for

@interface FakeTrack : NSObject
@property (nonatomic, strong) id URI;
@end
@implementation FakeTrack
@end

@interface FakeState : NSObject
@property (nonatomic, strong) FakeTrack *track;
@property (nonatomic) BOOL isPlaying, isPaused;
@end
@implementation FakeState
@end

static FakeState *sg_state;
static __weak id<SGPlayerStateObserver> sg_observer;
static NSMutableArray<NSString *> *sg_calls;

NSString *SGURIString(id uri) {
    if ([uri isKindOfClass:NSURL.class]) return [uri absoluteString];
    return [uri isKindOfClass:NSString.class] ? uri : nil;
}
void SGAddPlayerStateObserver(id<SGPlayerStateObserver> observer) { sg_observer = observer; }
SPTPlayerState *SGPlayerState(void) { return (SPTPlayerState *)sg_state; }

@interface FakePlayer : NSObject
@end
@implementation FakePlayer
- (id)skipToNextTrackWithOptions:(id)options {
    [sg_calls addObject:@"skip"];
    return nil;
}
@end
static FakePlayer *sg_player;
id SGKaraokePlayer(void) { return sg_player; }

// The class HeadGestures.x hooks, with the selectors Spotify's has.
@interface SPTCollectionPlatformImplementation : NSObject
@end
@implementation SPTCollectionPlatformImplementation
- (id)stateProvider { return nil; }
- (void)addURL:(NSURL *)url showUIConfirmation:(BOOL)show completion:(void (^)(void))completion {
    [sg_calls addObject:[NSString stringWithFormat:@"add %@ %@", url.absoluteString, show ? @"toast" : @"quiet"]];
    completion();
}
@end

#pragma mark - the headphones stood in for

@interface FakeAttitude : NSObject
@property (nonatomic) double pitch, yaw;
@end
@implementation FakeAttitude
@end

@interface FakeMotion : NSObject
@property (nonatomic) NSTimeInterval timestamp;
@property (nonatomic, strong) FakeAttitude *attitude;
@end
@implementation FakeMotion
@end

static CMHeadphoneDeviceMotionHandler sg_handler;
static NSOperationQueue *sg_motionQueue;
static BOOL sg_active;
static int sg_starts, sg_stops;
static double sg_clock = 100;

static void fakeStart(id self, SEL _cmd, NSOperationQueue *queue, CMHeadphoneDeviceMotionHandler handler) {
    sg_handler = handler;
    sg_motionQueue = queue;
    sg_active = YES;
    sg_starts++;
}
static void fakeStop(id self, SEL _cmd) {
    sg_active = NO;
    sg_stops++;
}
static BOOL fakeActive(id self, SEL _cmd) { return sg_active; }
static BOOL fakeAvailable(id self, SEL _cmd) { return YES; }
static CMAuthorizationStatus fakeAuthorized(id self, SEL _cmd) { return CMAuthorizationStatusAuthorized; }

static void takeOverMotion(void) {
    Class manager = CMHeadphoneMotionManager.class;
    method_setImplementation(class_getInstanceMethod(manager, @selector(startDeviceMotionUpdatesToQueue:withHandler:)), (IMP)fakeStart);
    method_setImplementation(class_getInstanceMethod(manager, @selector(stopDeviceMotionUpdates)), (IMP)fakeStop);
    method_setImplementation(class_getInstanceMethod(manager, @selector(isDeviceMotionActive)), (IMP)fakeActive);
    method_setImplementation(class_getInstanceMethod(manager, @selector(isDeviceMotionAvailable)), (IMP)fakeAvailable);
    // Asked already: the page's first-time start for the permission prompt stays out of the counts.
    method_setImplementation(class_getClassMethod(manager, @selector(authorizationStatus)), (IMP)fakeAuthorized);
}

// 25 attitudes a second, as AirPods send them, onto the manager's queue while it listens.
static void send(double pitch, double yaw) {
    sg_clock += 1.0 / 25;
    if (!sg_active) return;
    FakeMotion *motion = [FakeMotion new];
    motion.timestamp = sg_clock;
    motion.attitude = [FakeAttitude new];
    motion.attitude.pitch = pitch;
    motion.attitude.yaw = yaw;
    CMHeadphoneDeviceMotionHandler handler = sg_handler;
    [sg_motionQueue addOperationWithBlock:^{ handler((CMDeviceMotion *)motion, nil); }];
}
static void hold(double seconds) {
    for (int n = (int)(seconds * 25); n > 0; n--) send(0.1, 3.0);
}
static void doubleNod(double depth, double length) {
    for (int k = 0; k < 2; k++)
        for (int n = 0, steps = (int)(length * 25); n < steps; n++) {
            double s = sin(M_PI * n / steps);
            send(0.1 - depth * s * s, 3.0);
        }
    hold(2);
}
static void shake(double width, double hertz) {
    for (int n = 0, steps = (int)(4 / (2 * hertz) * 25); n < steps; n++) send(0.1, remainder(3.0 + width * sin(2 * M_PI * hertz * n / 25), 2 * M_PI));
    hold(2);
}

#pragma mark - the run

static void findViews(UIView *root, Class kind, NSMutableArray *found) {
    if ([root isKindOfClass:kind]) [found addObject:root];
    for (UIView *sub in root.subviews) findViews(sub, kind, found);
}

static NSInteger sg_nodBefore;

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UINavigationController *nav;
@property (nonatomic, strong) SPTCollectionPlatformImplementation *platform;
@end

@implementation AppDelegate

- (UITableView *)table {
    return ((UITableViewController *)self.nav.viewControllers.lastObject).tableView;
}

- (void)setPlaying:(BOOL)playing {
    sg_state.isPlaying = YES;   // Spotify's stays on while a loaded track is paused
    sg_state.isPaused = !playing;
    [sg_observer playerStateDidChange:(SPTPlayerState *)sg_state];
}

- (NSString *)alertTitle {
    UIViewController *shown = self.nav.presentedViewController;
    return [shown isKindOfClass:UIAlertController.class] ? shown.title : nil;
}

- (void)dismissAlert {
    [self.nav dismissViewControllerAnimated:NO completion:nil];
}

// The alert's button of that style, pressed: the alert goes and its handler runs.
- (void)press:(UIAlertActionStyle)style {
    UIAlertController *alert = (UIAlertController *)self.nav.presentedViewController;
    for (UIAlertAction *action in alert.actions) {
        if (action.style != style) continue;
        void (^handler)(UIAlertAction *) = [action valueForKey:@"handler"];
        [self.nav dismissViewControllerAnimated:NO completion:^{ if (handler) handler(action); }];
    }
}

- (NSArray<void (^)(void)> *)steps {
    return @[
        ^{
            check(sg_starts == 0, @"switch off, playing: not listening");
            UITableViewCell *cell = [self.table cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
            NSMutableArray<UISwitch *> *switches = [NSMutableArray array];
            findViews(cell, UISwitch.class, switches);
            [switches.firstObject setOn:YES animated:YES];
            [switches.firstObject sendActionsForControlEvents:UIControlEventValueChanged];
        },
        ^{
            check(sg_active, @"switch on, playing: listening");
            doubleNod(0.35, 0.4);
        },
        ^{
            check([sg_calls isEqualToArray:@[@"add spotify:track:4uLU6hMCjMI75M1A2tKUQC toast"]],
                  [NSString stringWithFormat:@"a double nod adds the track, calls %@", sg_calls]);
            [sg_calls removeAllObjects];
            shake(0.21, 2.5);
        },
        ^{
            check([sg_calls isEqualToArray:@[@"skip"]], [NSString stringWithFormat:@"a shake skips, calls %@", sg_calls]);
            [sg_calls removeAllObjects];
            doubleNod(0.17, 0.5);
        },
        ^{
            check(sg_calls.count == 0, [NSString stringWithFormat:@"a small slow double nod at the default does nothing, calls %@", sg_calls]);
            sg_state.track.URI = [NSURL URLWithString:@"spotify:episode:512ojhOuo1ktJprKbVcKyQ"];
            doubleNod(0.35, 0.4);
        },
        ^{
            check(sg_calls.count == 0, [NSString stringWithFormat:@"a double nod on an episode saves nothing, calls %@", sg_calls]);
            sg_state.track.URI = @"spotify:track:4uLU6hMCjMI75M1A2tKUQC";
            [self setPlaying:NO];
            check(!sg_active && sg_stops == 1, @"paused: stopped");
            // Learning listens whatever plays.
            [self.table.delegate tableView:self.table didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:1]];
        },
        ^{
            NSLog(@"[harness] learning started: %@", sg_active ? @"yes" : @"no");
        },
        ^{
            check([[self alertTitle] isEqualToString:@"Nod twice"], [NSString stringWithFormat:@"learning asks for a nod: %@", [self alertTitle]]);
            check(sg_active, @"learning while paused: listening");
            doubleNod(0.17, 0.5);
        },
        ^{}, ^{}, ^{},
        ^{
            check([[self alertTitle] isEqualToString:@"Learned"], [NSString stringWithFormat:@"after 4 s it says %@", [self alertTitle]]);
            check(SGInt(SGKeyHeadNod, 0) > 0, [NSString stringWithFormat:@"stored nod %ld", (long)SGInt(SGKeyHeadNod, 0)]);
            check(!sg_active, @"learning over, paused: stopped");
            [self dismissAlert];
            [self.table reloadData];
            [self setPlaying:YES];
            doubleNod(0.17, 0.5);
        },
        ^{
            check([sg_calls isEqualToArray:@[@"add spotify:track:4uLU6hMCjMI75M1A2tKUQC toast"]],
                  [NSString stringWithFormat:@"the small slow double nod, at what was learned, adds the track, calls %@", sg_calls]);
            [sg_calls removeAllObjects];
            [self setPlaying:NO];
            // No headphones: nothing arrives while it learns the shake.
            [self.table.delegate tableView:self.table didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:1 inSection:1]];
        },
        ^{}, ^{}, ^{}, ^{}, ^{},
        ^{
            check([[self alertTitle] isEqualToString:@"No motion came"], [NSString stringWithFormat:@"learning with nothing sent says %@", [self alertTitle]]);
            check(SGInt(SGKeyHeadShake, 0) == 0, @"nothing stored for the shake");
            [self dismissAlert];
            [self.table reloadData];
        },
        ^{
            // Learning the nod again, cancelled while a nod comes in.
            sg_nodBefore = SGInt(SGKeyHeadNod, 0);
            [self.table.delegate tableView:self.table didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:1]];
        },
        ^{
            check([[self alertTitle] isEqualToString:@"Nod twice"], [NSString stringWithFormat:@"learning asks again: %@", [self alertTitle]]);
            [self press:UIAlertActionStyleCancel];
            doubleNod(0.35, 0.4);
        },
        ^{
            check([self alertTitle] == nil, [NSString stringWithFormat:@"Cancel takes the alert away: %@", [self alertTitle]]);
            [self.table.delegate tableView:self.table didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:1]];
        },
        ^{
            check([[self alertTitle] isEqualToString:@"Still listening"], [NSString stringWithFormat:@"learning again before the cancelled one ends says %@", [self alertTitle]]);
            [self dismissAlert];
        },
        ^{}, ^{},
        ^{
            check([self alertTitle] == nil, [NSString stringWithFormat:@"a cancelled try says nothing when it ends: %@", [self alertTitle]]);
            check(SGInt(SGKeyHeadNod, 0) == sg_nodBefore, [NSString stringWithFormat:@"a cancelled try keeps the nod %ld, stored %ld", (long)sg_nodBefore, (long)SGInt(SGKeyHeadNod, 0)]);
            check(!sg_active, @"cancelled learning over, paused: stopped");
            [self.table.delegate tableView:self.table didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:2 inSection:1]];
        },
        ^{
            check([[self alertTitle] isEqualToString:@"Forget your nod and shake?"], [NSString stringWithFormat:@"Forget asks first: %@", [self alertTitle]]);
            [self press:UIAlertActionStyleDestructive];
        },
        ^{
            check(SGInt(SGKeyHeadNod, 0) == 0 && SGInt(SGKeyHeadShake, 0) == 0, @"Forget clears both");
            [self.table.delegate tableView:self.table didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:2 inSection:1]];
        },
        ^{
            check([[self alertTitle] isEqualToString:@"Nothing learned yet"], [NSString stringWithFormat:@"Forget with nothing learned says %@", [self alertTitle]]);
            [self dismissAlert];
        },
        ^{
            NSLog(@"[harness] %@", failures ? [NSString stringWithFormat:@"%d failed", failures] : @"all passed");
        },
    ];
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    NSUserDefaults *store = NSUserDefaults.standardUserDefaults;
    for (NSString *key in store.dictionaryRepresentation.allKeys)
        if ([key hasPrefix:@"spotifyglass.headgestures"]) [store removeObjectForKey:key];
    takeOverMotion();
    sg_calls = [NSMutableArray array];
    sg_player = [FakePlayer new];
    sg_state = [FakeState new];
    sg_state.track = [FakeTrack new];
    sg_state.track.URI = @"spotify:track:4uLU6hMCjMI75M1A2tKUQC";
    // Spotify reaching for its platform's state provider is what the hook keeps it from.
    self.platform = [SPTCollectionPlatformImplementation new];
    [self.platform stateProvider];
    [self setPlaying:YES];

    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.nav = [[UINavigationController alloc] initWithRootViewController:SGHeadGesturesSettingsPage()];
    self.window.rootViewController = self.nav;
    [self.window makeKeyAndVisible];

    [[self steps] enumerateObjectsUsingBlock:^(void (^step)(void), NSUInteger i, BOOL *stop) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((1.5 + i) * NSEC_PER_SEC)), dispatch_get_main_queue(), step);
    }];
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(AppDelegate.class));
    }
}
