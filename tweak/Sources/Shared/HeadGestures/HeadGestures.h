// AirPods gestures (Mod Settings > Player > AirPods gestures), under either look: a double nod adds the
// playing song to Liked Songs and a shake of the head skips it, read from the head motion that AirPods Pro,
// AirPods 3 and later, AirPods Max and some Beats report through CMHeadphoneMotionManager.
//
//     SGHeadDetector.m         the gestures out of the motion, plain C, tested on the Mac (harness/head-gestures)
//     HeadGestures.x           the motion listened to while the switch is on and Spotify plays, and what each
//                              gesture does: Spotify's player skips, its collection platform saves the track
//     HeadGesturesSettings.m   the page: the switch, the sensitivity, and learning one's own nod and shake
//
// HeadGestures.x owns the app's one CMHeadphoneMotionManager (iOS hands a manager's motion to one handler) and
// lends its motion to other features through SGHeadMotionListen: Sing's spatial voice listens there.
//
// Everything applies at once, without a restart.
// Threading: main thread only, but for the listeners' handlers.
#import <CoreMotion/CoreMotion.h>
#import <UIKit/UIKit.h>
#import "SGHeadDetector.h"

#define SGKeyHeadGestures @"spotifyglass.headgestures"
// A percentage the thresholds are divided by: over 100 a smaller move counts.
#define SGKeyHeadSensitivity @"spotifyglass.headgestures.sensitivity"
// What learning set, in thousandths of a radian a second; unset or 0 is the detector's default.
#define SGKeyHeadNod @"spotifyglass.headgestures.nod"
#define SGKeyHeadShake @"spotifyglass.headgestures.shake"

enum { SGHeadSensitivityMin = 50, SGHeadSensitivityMax = 200, SGHeadSensitivityStep = 10 };

// From the switch, the sensitivity and learning: listens or stops, and reads the thresholds again.
void SGHeadGesturesSettingsChanged(void);
// Whether this iPhone can read headphone motion at all (iOS 14 and up; the headphones are another matter).
BOOL SGHeadGesturesAvailable(void);
// Listens for `seconds` whatever plays and answers the threshold learned for `axis` (0 when the motion held
// no gesture) and how many samples came (0 when no headphones sent any, or motion is not allowed).
void SGHeadGesturesLearn(SGHeadAxis axis, double seconds, void (^done)(double threshold, NSInteger samples));
// Ends the learning that listens now, at once: nothing is stored, its done is never called, and the motion stops
// unless the gestures or another feature want it. A new learning can start straight after.
void SGHeadGesturesCancelLearn(void);

UIViewController *SGHeadGesturesSettingsPage(void);

// Head motion for another feature, under `name`; a nil handler takes it out. While any listener is in, the
// manager runs whatever the gestures' switch says. A handler is called on the motion's serial queue with every
// motion, and with nil when the motion stops: the headphones gone, the manager stopped, or the listener taken out.
void SGHeadMotionListen(NSString *name, void (^handler)(CMDeviceMotion *motion));
// Asks for Motion & Fitness now, while a page is in front, if it was never asked and nothing listens yet.
void SGHeadMotionAskPermission(void);
