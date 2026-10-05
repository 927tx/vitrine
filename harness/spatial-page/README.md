# Spatial voice page harness

The Sing page (`tweak/Sources/Shared/Sing/SingSettings.m`) and the Spatial voice page under it, with its preview
(`SGSpatialPreview.m`), on the real Settings/ framework. `stubs.m` stands in for Sing's state (a model on the
phone, Sing off) and for HeadGestures' motion, which it plays from a script of the head's yaw at 25 motions a
second while the preview listens; it also answers Motion & Fitness's permission as the launch line says.

    ./build.sh
    xcrun simctl install <udid> build/SpatialPageHarness.app
    xcrun simctl launch <udid> com.vojta.spatialpageharness on allowed head=60 spatial
    xcrun simctl io <udid> screenshot shot.png

Other agents use the simulator too: make a device of your own (`xcrun simctl create`) and address it by UDID.
`main.m` lists the setup words (`on`, `allowed`, `denied`, `head=sweep`, `head=<degrees>`, `width=<points>`,
`slow`) and the actions, played one every 0.7 s from 1 s in: `spatial` opens the page, `toggle`, `pop`, and `dump`,
which logs the rows, the header's size and what VoiceOver reads on the preview. The stub logs each listener
coming and going:

    xcrun simctl launch --console-pty <udid> com.vojta.spatialpageharness on allowed head=sweep spatial dump pop dump

Reduce Motion: `xcrun simctl spawn <udid> defaults write com.apple.Accessibility ReduceMotionEnabled -bool true`,
then launch again (and `false` after).

2026-10-06, iPhone 17 Pro on iOS 27.0: the Sing page's Spatial voice row reading On and opening the page; the
preview swaying with no permission, with Motion & Fitness denied (its caption), and following a head turned 60
degrees left (the voice 60 degrees right, back to about 36 after 10 s as the front follows); the listener taken
out on pop and back on push; Reduce Motion holding the disc still, the ripples gone, the turn faded to in steps;
the header growing with its caption at the largest text sizes, and the disc fitting a 320-point window.

What it does not cover: real AirPods (the yaw's sign is not yet heard, see SGSpatialVoiceAngle), how often they
send motion, and what the preview costs on a phone's battery.
