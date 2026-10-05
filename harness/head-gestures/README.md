# AirPods gestures harness

`SGHeadDetector.m` (Shared/HeadGestures) as the tweak compiles it, on the Mac, over head motion made up to
look like what AirPods report through `CMHeadphoneMotionManager`: 25 attitudes a second, pitch and yaw in
radians, with a little noise. Each trace says what it should fire, and the run fails when one does not.
The negatives (one nod, three nods, a glance each way, a turn, running, dancing, a gap in the samples)
matter as much as the gestures. Learning is run on a small slow nod and shake: the defaults miss them, what
was learned catches them, and a walk still fires nothing at what was learned. Learning keeps a threshold only
when the detector, set to it, fires on the recording: three nods and a double nod of 2 s learn nothing, and a
double nod with a hard settle, which the first margin reads as six swings, learns a closer threshold that fires.

    ./build.sh && build/head-gestures                 # the synthetic traces
    build/head-gestures <trace.csv> [nod] [shake]     # a recording, one "time,pitch,yaw" a line

The traces are synthetic. No recording from real AirPods has been run through it yet: one, logged as
`time,pitch,yaw` from `CMDeviceMotion.attitude`, goes through the second form.

## The hook and the page in the simulator (`sim/`)

The real `HeadGestures.x` (through Logos), its settings page and the detector, with Spotify's player and collection
platform stood in for and `CMHeadphoneMotionManager`'s start and stop taken over, so made-up motion reaches the
handler on the manager's own queue. It checks that nothing listens until the switch is on, a double nod adds the
playing track with Spotify's toast, a shake skips, an episode is not saved, pausing stops, learning listens while
paused and stores what it learned, learning with no motion says so, a learning alert's Cancel ends the
listening at once (but for another feature's, through SGHeadMotionListen) and keeps the nod that was stored, a
second Learn straight after starts at once, Forget shows only while something is learned, and asks before it
clears both.

    THEOS=$HOME/theos sim/build.sh && xcrun simctl install <udid> build/sim/HeadGesturesSim.app
    xcrun simctl launch <udid> com.vitrine.headgesturessim    # then read the [harness] lines from the log

2026-10-05, iPhone 17 Pro on iOS 27.0: all 15 checks pass, three runs in a row, with the cue's tones played
through AVAudioPlayer (the harness checks the calls, not the sound). With Cancel and Forget, all 24 pass; a simulator
slow enough to hold the alert's presentation for seconds makes the timed steps fail.
Since Cancel ends learning at once and Forget shows only while something is learned: all 30 pass, three runs in a
row, on the same simulator.
