# Vibrations settings harness

Mod Settings > Player > Vibrations (`tweak/Sources/Shared/Haptics/HapticsSettings.m`), its preview
(`SGVibrationsPreview.m`) and its cards: the real Settings/ framework (its slider row and its rows shown while a
switch is on), the real control taps (`SGFeedback.m`, which the simulator plays silently), and `stubs.m` for Music
Haptics' engine, which logs each call with the strength and the Follows choice the hook would read, and keeps
the preview's watcher for `pulse` to hand a tap of the music's to.

    THEOS=$HOME/theos ./build.sh
    xcrun simctl install <udid> build/HapticsPageHarness.app
    xcrun simctl launch <udid> com.vojta.hapticspageharness controls-off music follows=1 bottom dump
    xcrun simctl io <udid> screenshot shot.png

Other agents use the simulator too: make a device of your own (`xcrun simctl create`) and address it by UDID.
Every launch clears the `spotifyglass.redesign.haptics` keys first unless `keep` is on the line; `main.m` lists the
setup words (`controls-off`, `music`, `follows=<n>`, `slow`) and the actions, played one every 0.7 s from 1 s in:
flipping a switch, dragging a slider and letting go, VoiceOver's swipe on one, the ⓘ, a tap on a row (the Follows
row, then a name in its list), and `dump`, which logs the stored keys, what the hooks read and the rows shown:

    xcrun simctl launch --console-pty <udid> com.vojta.hapticspageharness controls-off bottom toggle=0.0 slide=0.1:40 \
        toggle=1.0 slide=1.1:150 swipe=1.1:-3 dump select=1.2 select=0.1 dump

`tap` taps the preview (as VoiceOver's double tap does) and `pulse=<intensity>` hands it a tap of Music Haptics';
with `slow` a screenshot every second or so catches the crest on its way out:

    xcrun simctl launch <udid> com.vojta.hapticspageharness slow tap

2026-09-19, iPhone 17 Pro (402pt) and iPhone 13 mini (375pt) on iOS 26.5: both switches off, Controls on with its
Strength, Music Haptics on in each Follows choice, the Follows list with a line under each choice, and the rows
fading in under a switch (`slow`); Controls at 40%, Music Haptics at 150% then 120% by VoiceOver and Beat stored
under their keys and read back by the hooks. The Audio effects page and an SGModPage without shown-while rows
(`harness/audio-effects-page`, `push=reference`) draw the same pixels as before the slider and visibility were added.

2026-10-05, iPhone 17 Pro on iOS 27.0: with `controls-off` the Strength row stays under Controls, greyed (`dump` marks
it), `select=2.1` on it leans the Controls switch 6pt towards on and springs it back, and `toggle=2.0` brings
Strength back to full strength without a row moving.

What it does not cover: a real finger on the slider, and how any strength feels, which only a phone can tell.

2026-10-06, iPhone 17 Pro on iOS 27.0: the page opens on the preview, its line reading Tap to feel Controls, Tap to
feel Music Haptics (`controls-off music`), the Native iOS note (`controls-off native`) or what to turn on
(`controls-off`), and Tap to feel Controls again once `toggle=0.0` turns Controls on; with `slow tap`, six shots
1.3 s apart show the middle dipping and one lit ring travelling out to the edge and the field settling back to
rest; with Reduce Motion on (`simctl spawn <udid> defaults write com.apple.Accessibility ReduceMotionEnabled -bool
true`) every ring lights at once and fades, nothing moving. With Generated, `tap` asks the engine for its preview kick
at the stored strength with the rumble, and each step of `slide=1.1:150` asks again at the new strength. The line
wraps under accessibility-medium text and the cards move down under it.

Not covered here: how the taps feel, whether the preview kick reaches a running engine on a phone, and the
music's pulses with real music playing (`pulse` stands in for them).
