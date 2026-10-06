# System menu harness

`Redesigned/ContextMenu/ContextMenu.x` and `Redesigned/Player/PlayerMenu.m` run for real against a mock of
Spotify's context menu sheet (`ContextMenu_InternalImpl.ContextMenuViewController` under its class name,
a table of rows with a delegate, inside a navigation controller), presented by a ⋯ button the way
Spotify's is. Speed, pitch, reverb and Animated artwork are stubs that log.

    THEOS=$HOME/theos ./build.sh
    xcrun simctl install <udid> build/SystemMenuHarness.app
    xcrun simctl launch --console-pty <udid> com.vitrine.systemmenuharness <scenario>

Each run taps ⋯ at 1 s, waits for the sheet's presentation to end (the simulator takes a second or more
over the first one), and prints `PASS` or `FAIL` lines, then `done`. A pick, or opening a submenu, goes
through the menu view's own selection (`_UIContextMenuView`'s `_handleSelectionForElement:`), the harness's
only private call; the mod's own lines (`SGLog`) go to the unified log.

Every scenario but `fallback` first checks the top level: the sheet is hidden (its container at alpha 0),
the system menu is up with the quick row (Share, Add to Playlist, Add to Queue), Speed, Pitch & Reverb, Show
Animated Artwork and More, none of Spotify's other rows at the top, and the anchor takes touches.

- `rows`: More holds Go to album and the greyed-out, disabled Lyrics, and not the rows the quick row has;
  picking Go to album selects it on the sheet, which goes, and the anchor gives its touches back.
- `loading`: the sheet has no rows when the menu comes up; More opened then shows none, the rows come into
  the open More once the sheet has them, and Go to album fires.
- `quick`: Add to Queue is picked before the sheet has its rows, which come 1 s after the menu has gone; the
  pick waits for them and selects Spotify's Add to queue.
- `quicklate`: Add to Playlist is picked and the rows never come: after 2 s Spotify's sheet is shown.
- `podcast`: a sheet with no Add to playlist row, its rows late: once they are in, the quick row drops Add to
  Playlist while the menu is up, and More holds Go to show.
- `close`: closing the menu with no pick dismisses the sheet, and a second tap opens it again.
- `subpage`: the quick Share selects Spotify's Share, which pushes a page inside the sheet instead of
  closing it, so the sheet is shown.
- `sort`: a row of the mod's own in the sheet's header (as the playlist's Sort) is in More and fires.
- `animated`: Show Animated Artwork switches it on and the sheet goes.
- `fallback`: neither `performPrimaryAction` nor `_presentMenuAtLocation:` does anything, so the sheet
  shows at once and the anchor takes no touches.
- `show`, `showmore`, `showsound`: the menu, More or Speed, Pitch & Reverb held open, for a screenshot
  (`xcrun simctl io <udid> screenshot`); these never exit.
