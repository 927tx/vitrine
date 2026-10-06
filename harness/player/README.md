# Player harness

Spotify's full screen player mocked under its own class names and accessibility identifiers
(from `trees/clean/player/01.txt`), so the redesign's player can be laid out, animated and
looked at on the Mac without the phone.

    THEOS=$HOME/theos ./build.sh
    xcrun simctl install <udid> build/PlayerHarness.app
    SIMCTL_CHILD_HARNESS_SCENARIO=artwork xcrun simctl launch --console-pty <udid> com.vojta.playerharness
    xcrun simctl io <udid> screenshot shot.png

Launch it on a simulator by UDID; it has a scene delegate (`../scene.m`), so the iOS 27 runtime runs it
too. `SRC=<another checkout>/tweak/Sources OUT=<dir> ./build.sh` builds it against other
sources, for example an older commit, to see a bug before its fix.

`build.sh` runs `logos.pl -c generator=internal` over `PlayerLyrics.x`, `PlayerArtwork.x`,
`PlayerFooter.x`, `PlayerScroll.x`, `PlayerField.x` and the Kit's `SGRBridges.x`, and links them with
the real `Core/`, `Redesigned/Kit/`, `SGRKaraokeView`, `Settings/` and the Player page. `stubs.m` stands in for the hooks the harness
does not compile (the Kit's accent and repaint, the rest of the player, the lyrics store, the haptics,
Sing's mic) and plays a mock player: `SGRHarnessSetTrack` reports a track, with the image ids Spotify's
metadata carries, to every state observer. A song of ten timed lines plays on from launch. `main.m` also answers
for i.scdn.co through an `NSURLProtocol` handed to every session, so each picture the Kit fetches can
come late, out of order, or not at all.

`HARNESS_SCENARIO` picks what the harness does:

- `lyrics` (default) opens the lyrics at 2 s, closes them at 6 and opens them again at 10.
- `look` plays one track, then a track from another album at 8 s, whose picture reaches the screens
  0.4 s later. It shows the field, the moving background and its crossfade, and the footer row. At 3 s
  it logs whether touches on the lowered footer row (issue #54) still reach it.
- `artwork` is issue #58. Tracks change while the covers on screen lag behind (3.5 s late, past the
  Kit's last look), two skips come in a row with the older picture answering last, and one track plays
  offline. Each step checks by colour that the Kit and the field show that track's picture, and the log
  ends with `artwork checks: n of 4 right -- PASS` or `FAIL`. Before the fix it read 1 of 4.
- `landscape` turns the lyrics sideways at 3 s, puts a line's meanings over them (the real
  `MeaningSheet.m`) at 4 s and takes them away at 9, then pauses at 14.5 and resumes at 15.5. Each step
  logs whether the controls are up and whether a touch on the lines lands on the lines or on the shield
  that brings the controls back, with `ok` or `WRONG`. At 6 s it logs the sheet's frame: a card inside
  the safe area with a grabber, where the sheet before it covered the whole screen. It also logs that the
  window comes up clear and fades in, dark, that every button has a label and 44pt, and at 22 s that
  VoiceOver's escape takes the screen away and gives the key back to the player.
- `scroll` moves the list up and down in code and logs whether it stayed at its top, then scrubs a mock of
  the progress bar's slider in code (issue #172): the list's pan off while it tracks, back at its end, at a
  cancel and when the slider leaves the window, and a pan that was off already left off. The log ends
  with `scrub checks: ... -- PASS` or `FAIL`.
- `cover` is issue #77. The cover is checked untouched first, then given Spotify's layout for a track with
  lyrics, a smaller cover over the lyric preview, and must take its room back as a centred square the
  Kit also reports. The log ends with `cover checks: n of 4 right -- PASS` or `FAIL`.
- `immersive` opens the lyrics and waits past the rest: only the bottom stack under the title row
  (progress bar, buttons, volume row, footer) fades, the lines grow down only, a touch where the buttons
  were lands on the lines, the thumbnail takes its own, and the lines' tap is off. Then the tap that
  wakes them (fired in code), a scroll that hides them again and the thumbnail closing the lyrics. The
  log ends with `immersive checks: n of 10 right -- PASS` or `FAIL`.
- `badge` shows the hold's 2× badge on the cover by hand, holds again while it fades out and lets go.
  The log ends with `badge checks: n of 3 right -- PASS` or `FAIL`.

- `motion` is Animated artwork. The clip, `HARNESS_CANVAS_FILE` (any mp4, `harness/fluid-clip` writes one),
  is served as the track's Canvas before the player's background has laid out; then the background lays
  out, the lyrics open and close, the background is built again, and the ⋯ menu's switch goes off, on, and
  off with the player out of its window. Each step is checked (the clip on the field, the cover hidden, the
  poster under the video and the Fluid field held under it, the foot and the blur, the thumbnail, the clip
  and the cover crossing over half way through the switch). Then the song pauses and plays (the clip's rate
  0, then 1), a mock of Spotify's video unit attaches and detaches its video (the clip goes and comes back),
  a track comes with no Canvas and then again with one (the clip comes in late), and a skip to a track whose
  clip is in the store keeps the last clip until the new one is over it, the cover hidden throughout. The log
  ends with `motion checks: n of 20 right -- PASS` or `FAIL`.

- `settings` opens the redesign's Player page (`PlayerSettings.m`, with the real `Settings/` framework) over the
  player at 3 s, with the clip of `motion` in. It checks the card leads the page with the four backgrounds'
  segmented control under it, the Mini player section's three rows are on the page, and then, as the control
  picks each in turn, that the card shows Animated (the clip, the sources and Low Data Mode's rows in), Fluid,
  Colours, Still and Animated again, with a note for each and the header the same height throughout. The log
  ends with `settings checks: n of 7 right -- PASS` or `FAIL`.

`HARNESS_VOLUME=0` leaves out the volume row that the phone has and the tree does not.

A screen recording is the way to see a move:

    xcrun simctl io <udid> recordVideo -f run.mp4      # ^C to stop
    ffmpeg -ss 7.4 -t 2.2 -i run.mp4 -vf "fps=5,scale=180:-1,tile=11x1" -frames:v 1 strip.png

It also lays every unit out once a second, which is what the transforms on Spotify's title row and the
narrowed marquee labels have to survive.

What it does not cover: the real element framework's autolayout, Spotify's own scrolled layout, the
player's open and close transition, and Spotify's real image loading.
