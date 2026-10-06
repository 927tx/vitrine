# Tab bar harness

The bottom of Spotify's main screen mocked under its own class names, so `Redesigned/Navbar/TabBar.x`
and `Redesigned/NowPlayingBar/NowPlayingBar.x` run for real over it on the Mac without the phone: the
tab bar container with Spotify's bar and its row of tabs, a page with a list on the tab's stack, the
now playing bar's page with its card, and Spotify's message bar (`LimitedExperienceIndicatorBar`, what
Offline and Private Session show) under the tab bar. It plays issue #33.

    THEOS=$HOME/theos ./build.sh
    xcrun simctl install <udid> build/TabBarHarness.app
    xcrun simctl launch <udid> com.vojta.tabbarharness shown
    xcrun simctl io <udid> screenshot shot.png

`build.sh` runs `logos.pl -c generator=internal` over `TabBar.x` and `NowPlayingBar.x` from the
checkout it sits in and links them with the real `Core/` and `SGRTokens.m`; `SRC=<other tweak/Sources>
./build.sh` builds an older tree instead, to compare. `stubs.m` stands in for the accent and repaint
hooks, the tab bar's composition and Mod Settings. iOS 27 ends an app with no scene delegate at
launch, so the harness has one.

The layout is the one 9.1.78 makes in a compact width, with the addresses it was read from:

- `TabBarContainerImpl`'s view has a guide from 49 pt above its safe area's bottom to its bottom
  (`viewDidLoad`, 0x1008409a8); the stack holding the tab bar is as tall as the guide and stands on
  the view's bottom, and the tab bar is as tall as the stack (0x106fabb7c).
- The page on the tab's stack gets 49 pt of safe area on top of the container's (0x10707bde4). The now
  playing bar's share of the pages' inset comes another way in Spotify; here it is a stand-in of 64 pt
  on the page, so the list's end marks where Spotify thinks the bars begin.
- The chrome puts the tab bar container above the message bar, and the now playing bar's page (64 pt,
  its content 8 pt above its bottom, 0x105345190) on the container's guide's top, which is the bottom
  anchor `MainUIContainer` gives the chrome (0x100ae0178).
- The message bar is its message plus the safe area it pads the message by, 22 pt here.

Launch words: `none` no message bar; `shown` one sliding in at 1.5 s; `away` one there from the start,
sliding away at 1.5 s; `cycle` in at 1.5 s and out at 4.5 s, for a recording. At 2.5 s everything is
logged in window points, with the gap between the bottom of the now playing card and the top of the
glass bar's platter (8 pt is the redesign's own, on a Face ID phone with nothing under the bar), and
half way through a slide what the screen shows of the message bar, the tab bar and the now playing bar:

`split` after the first word makes Search a split tab (stubs.m answers `SGRTabIsApart` for it), so it
stands on a glass bar of its own, and the platters of both bars are logged. `pick` picks Search at 2 s and
Home at 4 s through the system bar's delegate, the mock tab repainting its label white as Spotify's does,
and logs which bar selects what after each: `xcrun simctl launch <udid> com.vojta.tabbarharness pick split`.

    xcrun simctl spawn <udid> log show --last 1m --style compact --predicate 'eventMessage CONTAINS "[harness]" OR eventMessage CONTAINS "tab bar:"'

`mini` minimizes the bar at 1 s through `SGRSetTabBarMinimized`, logs at 2.5 s and expands it again at 3.5 s,
logging at 5 s. Minimized, the platters should be two 62 pt circles 21 pt in from each side, the card
between them 8 pt from each, centred on them, and a touch at the card's middle should land in the now
playing bar (through the hook on the page's `TouchPassthroughView`); expanded again, all as `none` has
it. Every report also gives the frame of the fade under the bars. The mock card's labels have fixed
frames, so how Spotify's own content takes the narrower card is not shown here.

`minimize-check.c` runs the scroll's steps (`MinimizeStep.h`) on the Mac:

    cc -I../../tweak/Sources/Redesigned/Navbar minimize-check.c -o build/minimize-check && build/minimize-check

`jam` plays a Jam: a strip under the class name of Spotify's (a SwiftUI hosting view of
`Jam_AttachmentsImpl.JamHatElement`, 44 pt) over the card, both in a view painted the album colour too,
the bar 44 pt taller, and the strip gone again at 3.5 s. The log then lists the bar's glass panes. The
card's glass should be the track card's (386x56), the strip's pane 36 pt above it with a 4 pt gap, and
once the Jam is over the card's glass should still be 386x56 and the strip's pane should have no effect.
Before the fix the card's glass was the painted view around both, cut to 80 pt, over the strip and
the top 36 pt of the track. How Spotify really nests the strip is not known; this is one way the spec's description
allows.

Before the fix the gap was -26 pt with nothing under the bar on an iPhone SE, and with the message bar
up on any phone: UIKit's glass bar is 83 pt, Spotify's bar was its 49 pt row with no inset under it,
and the glass bar stood the difference above it, over the now playing bar.

What it does not cover: Spotify's own chrome, which is Swift with no symbols (the constraints above
are read from its code, not run), the real now playing bar's content and its page's inset, the tab
bar hidden by a page, the player's open and close over the bars, and a regular width.
