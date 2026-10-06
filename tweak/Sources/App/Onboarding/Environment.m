// What about the install itself can work against the mod, said once and kept at the top of Mod Settings
// while it lasts: EeveeSpotify injected beside it, a Spotify other than the one it is made for, and a
// redesign below iOS 26 that did not start (Core/SGUIMode.h), which turned itself off.
#import "Shared/Lyrics/Lyrics.h"
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "Onboarding.h"

static NSString *const kTold = @"spotifyglass.environment.told";
static const NSTimeInterval kSettle = 4;   // after the first activation, behind the signing sheet's 3 s
static const NSTimeInterval kRetry = 4;
static const NSInteger kTries = 45;        // three minutes of waiting for the screen, then the rows say it

// A problem is its title and what it means, @[title, body].
typedef NSArray<NSString *> *SGProblem;

NSString *SGSpotifyVersion(void) {
    return [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown";
}

// A Spotify whose version can be read and is not the one the mod is made for; one that cannot be read
// says nothing, rather than "Spotify unknown".
static BOOL otherVersion(void) {
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    return [version isKindOfClass:NSString.class] && ![version isEqualToString:SGSpotifyMadeFor];
}

static SGProblem eevee(void) {
    return @[@"EeveeSpotify is injected too",
             @"Vitrine already blocks ads and brings lyrics, and EeveeSpotify hooks the same parts of Spotify. With both, Spotify can freeze as it starts or show the wrong lyrics. Sign Spotify again without EeveeSpotify."];
}

static SGProblem version(void) {
    return @[[NSString stringWithFormat:@"Spotify %@ is not the version Vitrine is made for", SGSpotifyVersion()],
             [NSString stringWithFormat:@"Vitrine is made for Spotify %@. On another version some of its changes find nothing to change, and some screens can look wrong or crash. Inject Vitrine into Spotify %@.",
                 SGSpotifyMadeFor, SGSpotifyMadeFor]];
}

static SGProblem fellBack(void) {
    return @[@"The redesign did not start",
             [NSString stringWithFormat:@"Spotify did not get going with the redesign on iOS %@, so it is back in Legacy and Redesigned UI is off. Mod Settings can turn it on again.",
                 UIDevice.currentDevice.systemVersion]];
}

// One problem is the alert's title and message; several are a paragraph each under a count.
static void tell(NSArray<SGProblem> *list) {
    NSString *title = list.count == 1 ? list[0][0] : [NSString stringWithFormat:@"%lu things to know", (unsigned long)list.count];
    NSMutableArray<NSString *> *paragraphs = [NSMutableArray array];
    for (SGProblem problem in list) {
        [paragraphs addObject:list.count == 1 ? problem[1] : [NSString stringWithFormat:@"%@.\n%@", problem[0], problem[1]]];
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                  message:[paragraphs componentsJoinedByString:@"\n\n"]
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

// What about the install is worth saying.
static NSArray<SGProblem> *installProblems(void) {
    NSMutableArray<SGProblem> *list = [NSMutableArray array];
    if (SGEeveeSpotifyInjected()) [list addObject:eevee()];
    if (otherVersion()) [list addObject:version()];
    return list;
}

// The rows stay while the install is so; the fall back is said once and is over.
NSArray<SGModRow *> *SGEnvironmentWarningRows(void) {
    NSMutableArray<SGModRow *> *rows = [NSMutableArray array];
    if (SGEeveeSpotifyInjected())
        [rows addObject:SGWarningRow(@"EeveeSpotify is injected too", @"Tap for what that does", ^{ tell(@[eevee()]); })];
    if (otherVersion())
        [rows addObject:SGWarningRow([NSString stringWithFormat:@"Made for Spotify %@", SGSpotifyMadeFor],
                                     [NSString stringWithFormat:@"This is %@. Tap for what that does", SGSpotifyVersion()],
                                     ^{ tell(@[version()]); })];
    return rows;
}

// Once per install state: the same EeveeSpotify and the same Spotify version say nothing again, a
// change says what it is now.
static NSString *state(void) {
    return [NSString stringWithFormat:@"eevee %d, spotify %@", SGEeveeSpotifyInjected(), SGSpotifyVersion()];
}

static void tellWhenClear(NSInteger tries) {
    UIViewController *top = SGTopController();
    // The tour, What's new and the signing sheet own the screen first; an alert presented from one of
    // them lands nowhere, so this one waits its turn. It also waits for the app to be in front, so it is
    // not shown, and counted as told, to someone who sent Spotify away in its first seconds.
    BOOL front = UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    if (!front || !top || SGOnboardingShowing() || [top isKindOfClass:UIAlertController.class]) {
        if (tries <= 0) return;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kRetry * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            tellWhenClear(tries - 1);
        });
        return;
    }
    // The fall back is news every time; the install's state only when it changed.
    NSUserDefaults *store = NSUserDefaults.standardUserDefaults;
    NSMutableArray<SGProblem> *list = [NSMutableArray array];
    if (SGRedesignFellBack()) [list addObject:fellBack()];
    if (![[store stringForKey:kTold] isEqualToString:state()]) {
        [store setObject:state() forKey:kTold];
        [list addObjectsFromArray:installProblems()];
    }
    if (list.count) tell(list);
}

void SGCheckEnvironmentOnce(void) {
    __block id token = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                                      object:nil
                                                                       queue:nil
                                                                  usingBlock:^(NSNotification *note) {
        [NSNotificationCenter.defaultCenter removeObserver:token];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSettle * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (SGEeveeSpotifyInjected()) SGLog(@"environment: EeveeSpotify is injected too");
            if (otherVersion()) SGLog(@"environment: Spotify %@, made for %@", SGSpotifyVersion(), SGSpotifyMadeFor);
            tellWhenClear(kTries);
        });
    }];
}
