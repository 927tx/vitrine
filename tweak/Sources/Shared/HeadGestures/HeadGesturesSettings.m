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

// Set while learning listens, a cancelled try too: SGHeadGesturesLearn runs its seconds out either way.
static BOOL sg_listening;

static void learn(SGHeadAxis axis) {
    if (!SGHeadGesturesAvailable()) {
        say(@"No head tracking", @"This iPhone cannot read the motion of headphones.");
        return;
    }
    if (sg_listening) {
        say(@"Still listening", @"The last try is finishing. Try again in a few seconds.");
        return;
    }
    BOOL nod = axis == SGHeadAxisPitch;
    NSString *key = nod ? SGKeyHeadNod : SGKeyHeadShake;
    // SGHeadGesturesLearn stores what it found itself, so a cancelled try puts the old size back.
    NSInteger before = SGInt(key, 0);
    __block BOOL cancelled = NO;
    UIAlertController *asking = [UIAlertController alertControllerWithTitle:nod ? @"Nod twice" : @"Shake your head"
        message:nod ? @"Now, the way you would to like a song." : @"Now, the way you would to skip a song."
        preferredStyle:UIAlertControllerStyleAlert];
    [asking addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) { cancelled = YES; }]];
    [SGTopController() presentViewController:asking animated:YES completion:^{
        sg_listening = YES;
        SGHeadGesturesLearn(axis, kLearnSeconds, ^(double threshold, NSInteger samples) {
            sg_listening = NO;
            if (cancelled) {
                if (SGInt(key, 0) != before) {
                    SGSetInt(key, before);
                    SGHeadGesturesSettingsChanged();
                }
                return;
            }
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

// Both learned sizes back to the defaults, asked first. With nothing learned there is nothing to ask.
static void forget(void) {
    if (SGInt(SGKeyHeadNod, 0) <= 0 && SGInt(SGKeyHeadShake, 0) <= 0) {
        say(@"Nothing learned yet", @"Your nod and your shake use the default sizes.");
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Forget your nod and shake?"
        message:@"Both go back to the default sizes. You can learn them again." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Forget" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        SGSetInt(SGKeyHeadNod, 0);
        SGSetInt(SGKeyHeadShake, 0);
        SGHeadGesturesSettingsChanged();
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

UIViewController *SGHeadGesturesSettingsPage(void) {
    SGModRow *toggle = SGOptionRow(@"AirPods gestures", @"Nod twice to like the song, shake your head to skip it", SGKeyHeadGestures);
    toggle.changed = ^(BOOL on) { SGHeadGesturesSettingsChanged(); };
    BOOL (^on)(void) = ^BOOL { return SGFlag(SGKeyHeadGestures, NO); };

    SGModRow *sensitivity = SGSliderRow(@"Sensitivity", @"Higher counts a smaller move",
        SGHeadSensitivityMin, SGHeadSensitivityMax, SGHeadSensitivityStep,
        ^double { return MAX(SGHeadSensitivityMin, MIN(SGHeadSensitivityMax, SGInt(SGKeyHeadSensitivity, 100))); },
        ^(double value) {
            SGSetInt(SGKeyHeadSensitivity, lround(value));
            SGHeadGesturesSettingsChanged();
        },
        ^NSString *(double value) { return [NSString stringWithFormat:@"%ld%%", lround(value)]; });
    sensitivity.visible = on;

    SGModRow *nod = SGStatActionRow(@"Learn your nod", nil, ^NSString *{ return learnedValue(SGKeyHeadNod); }, ^{ learn(SGHeadAxisPitch); });
    SGModRow *shake = SGStatActionRow(@"Learn your shake", nil, ^NSString *{ return learnedValue(SGKeyHeadShake); }, ^{ learn(SGHeadAxisYaw); });
    // Shown whenever the switch is on: SGModPage asks `visible` again only when a switch flips or the page
    // comes back, not after an alert, so a row hidden until something is learned would stay hidden.
    SGModRow *forgetRow = SGActionRow(@"Forget what it learned", nil, ^{ forget(); });
    forgetRow.color = SGRed();
    for (SGModRow *row in @[nod, shake, forgetRow]) row.visible = on;

    return [[SGModPage alloc] initWithTitle:@"AirPods gestures" intro:nil sections:@[
        SGSection(nil, @[SGWithSymbol(toggle, @"airpods.pro"), sensitivity]),
        SGNotedSection(@"Learn", @[nod, shake, forgetRow],
            @"Learning listens for a few seconds and sets how big a move counts, from yours. The gestures work while "
            "Spotify plays through headphones that track head motion. A tone in the music confirms each one, a rising pair when "
            "it worked and a low one when it did not, with the iPhone on silent too."),
    ] footer:nil];
}
