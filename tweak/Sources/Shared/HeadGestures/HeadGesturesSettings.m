// The AirPods gestures page: the switch, the sensitivity, and learning one's own nod and shake. Learning
// listens for a few seconds under an alert that says what to do, then says what it found.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "HeadGestures.h"

// Long enough for a slow double nod and a breath before it.
static const double kLearnSeconds = 4;

static NSString *learnedValue(NSString *key) {
    return SGInt(key, 0) > 0 ? @"Learned" : @"Default";
}

static void say(NSString *title, NSString *message) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

static BOOL anythingLearned(void) {
    return SGInt(SGKeyHeadNod, 0) > 0 || SGInt(SGKeyHeadShake, 0) > 0;
}

// `done` runs once something may be stored, before the alert that says what: the page shows Forget then.
static void learn(SGHeadAxis axis, void (^done)(void)) {
    if (!SGHeadGesturesAvailable()) {
        say(@"No head tracking", @"This iPhone cannot read the motion of headphones.");
        return;
    }
    BOOL nod = axis == SGHeadAxisPitch;
    // Cancel tapped while the alert was still coming in: learning never starts.
    __block BOOL cancelled = NO;
    UIAlertController *asking = [UIAlertController alertControllerWithTitle:nod ? @"Nod twice" : @"Shake your head"
        message:nod ? @"Now, the way you would to like a song." : @"Now, the way you would to skip a song."
        preferredStyle:UIAlertControllerStyleAlert];
    [asking addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        cancelled = YES;
        SGHeadGesturesCancelLearn();
    }]];
    [SGTopController() presentViewController:asking animated:YES completion:^{
        if (cancelled) return;
        SGHeadGesturesLearn(axis, kLearnSeconds, ^(double threshold, NSInteger samples) {
            done();
            [asking dismissViewControllerAnimated:YES completion:^{
                if (samples == 0)
                    say(@"No motion came", @"Put in AirPods that track head motion (AirPods Pro, AirPods 3 or later, "
                        "AirPods Max), and allow Spotify in Settings > Privacy & Security > Motion & Fitness.");
                else if (threshold <= 0)
                    say(nod ? @"No double nod found" : @"No shake found",
                        nod ? @"Nod twice, down and up, a little quicker." : @"Shake your head left and right, a little quicker.");
                else
                    say(@"Learned", nod ? @"A double nod this size likes the song." : @"A shake this size skips the song.");
            }];
        });
    }];
}

// Both learned sizes back to the defaults, asked first; `done` runs once they are.
static void forget(void (^done)(void)) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Forget your nod and shake?"
        message:@"Both go back to the default sizes. You can learn them again." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Forget" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        SGSetInt(SGKeyHeadNod, 0);
        SGSetInt(SGKeyHeadShake, 0);
        SGHeadGesturesSettingsChanged();
        done();
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

UIViewController *SGHeadGesturesSettingsPage(void) {
    SGModRow *toggle = SGOptionRow(@"AirPods gestures", @"Nod twice to like the song, shake your head to skip it", SGKeyHeadGestures);
    toggle.changed = ^(BOOL on) { SGHeadGesturesSettingsChanged(); };

    SGModRow *sensitivity = SGSliderRow(@"Sensitivity", @"Higher counts a smaller move",
        SGHeadSensitivityMin, SGHeadSensitivityMax, SGHeadSensitivityStep,
        ^double { return MAX(SGHeadSensitivityMin, MIN(SGHeadSensitivityMax, SGInt(SGKeyHeadSensitivity, 100))); },
        ^(double value) {
            SGSetInt(SGKeyHeadSensitivity, lround(value));
            SGHeadGesturesSettingsChanged();
        },
        ^NSString *(double value) { return [NSString stringWithFormat:@"%ld%%", lround(value)]; });
    sensitivity.waitsOn = SGKeyHeadGestures;

    // Learning and forgetting change what Forget's row reads, which no switch on the page tells it.
    __block __weak SGModPage *page;
    void (^refresh)(void) = ^{ [page refreshVisibility]; };
    SGModRow *nod = SGStatActionRow(@"Learn your nod", nil, ^NSString *{ return learnedValue(SGKeyHeadNod); }, ^{ learn(SGHeadAxisPitch, refresh); });
    SGModRow *shake = SGStatActionRow(@"Learn your shake", nil, ^NSString *{ return learnedValue(SGKeyHeadShake); }, ^{ learn(SGHeadAxisYaw, refresh); });
    SGModRow *forgetRow = SGActionRow(@"Forget what it learned", nil, ^{ forget(refresh); });
    forgetRow.color = SGRed();
    forgetRow.visible = ^BOOL { return anythingLearned(); };
    nod.waitsOn = shake.waitsOn = forgetRow.waitsOn = SGKeyHeadGestures;

    SGModPage *shown = [[SGModPage alloc] initWithTitle:@"AirPods gestures" intro:nil sections:@[
        SGSection(nil, @[SGWithSymbol(toggle, @"airpods.pro"), sensitivity]),
        SGNotedSection(@"Learn", @[nod, shake, forgetRow],
            @"Learning listens for a few seconds and sets how big a move counts, from yours. The gestures work while "
            "Spotify plays through headphones that track head motion. A tone in the music confirms each one, a rising pair when "
            "it worked and a low one when it did not, with the iPhone on silent too."),
    ] footer:nil];
    page = shown;
    return shown;
}
