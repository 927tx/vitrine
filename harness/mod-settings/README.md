# Mod Settings harness

Mod Settings' main page as `App/ModSettings.x` builds it, opened through `SGOpenModSettings` and pushed onto a
navigation stack as on the phone, with the real `App/Pages.m` behind the Redesigned UI switch and the real
`Settings/` framework. `build.sh` runs `ModSettings.x` through `logos.pl -c generator=internal`; its hooks on
Spotify's settings list and side drawer find no class here and do nothing. `stubs.m` stands in for every page a
row opens (an empty page of that name), the values beside the chevrons (Off) and the update and signing checks.

    THEOS=$HOME/theos ./build.sh
    xcrun simctl install <udid> build/ModSettingsHarness.app
    xcrun simctl launch --console-pty <udid> com.vitrine.modsettingsharness redesign warning dump
    xcrun simctl io <udid> screenshot shot.png

Make a simulator of your own (`xcrun simctl create`) and address it by UDID. `main.m` lists the setup words
(`redesign`, `warning`, `keep`) and the actions: `toggle=<section>.<row>` flips a switch the way a tap does,
`cancel` closes the alert it brings up, `bottom` scrolls to the end, and `dump` logs the rows of every section.

2026-10-06, iPhone 17 Pro on iOS 27.0: the warning row leads; then Redesigned UI (glowing, with its ⓘ), Appearance
and Tab bar; Player, Lyrics and Albums & artists (Home & Library in the native look); Sing, Spatial voice, Audio
effects, Vibrations, Live Activity, AirPods gestures and Listening stats; Lock screen and Premium, ads & privacy; Labs and
All flags; Mod with the version. Flipping Redesigned UI on in the native look offers the restart and swaps Home &
Library for Albums & artists in place.

What it does not cover: the pages the rows open, the row the mod adds to Spotify's settings list and side drawer,
and iOS below 26, where the switch warns first.
