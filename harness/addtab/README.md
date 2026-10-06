# Add a Tab harness

The Add a Tab sheet (`Shared/Navigation/AddTabSheet.m`) and the icon catalogues (`TabIcons.m`) run for
real in the simulator, over a stand-in for Spotify's `SPTEncoreIcon` (eight glyphs drawn as SF Symbols,
plus class methods that are not glyphs) and `SPTEncoreIconView`. `Links.x` is compiled as it is; with no
link dispatcher every route is "unknown", which lets a link through as it does before Spotify sets the
dispatcher up.

    THEOS=$HOME/theos ./build.sh
    xcrun simctl install <udid> build/AddTabHarness.app
    xcrun simctl launch <udid> com.vitrine.addtabharness added
    xcrun simctl io <udid> screenshot shot.png
    xcrun simctl spawn <udid> log show --last 1m --style compact --predicate 'process == "AddTabHarness" AND (eventMessage CONTAINS "[harness]" OR eventMessage CONTAINS "add tab")'

Launch words: `sheet` the sheet as it opens; `preset` Liked Songs picked, which fills the name and the
icon; `glyphs` Choose an Icon on Encore; `symbols` Choose an Icon searching SF Symbols for "heart";
`pick` one of those results tapped while the search is up, then the page it lands on logged; `added`
Liked Songs with the SF Symbol music.mic added, the tab logged. The glyphs the enumeration kept and how
long the SF Symbol list took to read are logged on every launch.

What it does not cover: Spotify's real Encore classes and router, a real finger (the steps call the
table's delegate and set the search text), the keyboard over the compact detent, and iPad.
