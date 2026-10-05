# Local files check

`./build.sh` checks `Shared/LocalFiles/LocalFiles.m` as the tweak compiles it: a `spotify:local:` URI
read back into its names (form decoded, a `%3A` in a title too), an edit laid over them, and the lyrics
key each edit gives. A rename gets a new key (`<uri>#<number>`), the same names saved again or a new
cover with them keep it, a cover alone on an unedited file leaves the bare URI, and names back to the
file's own go back to it. It also checks a stored cover's `spotify:localfileimage:` address and its way
back, that no other path comes back through it, and that a replaced or dropped cover's file is removed.

It runs on the Mac as a Mac Catalyst binary with `CFFIXED_USER_HOME` set to `build/home`, so its
defaults and its covers never reach the Mac's own.

It does not cover the hooks in `LocalFileInfo.x` or the lyrics engine asking for the
new key (`Shared/Lyrics/KaraokeSource.x`).

## Edit info in the simulator

`sim/build-sim.sh <udid>` builds `EditInfoMenu.x` and `LocalFiles.m` as the tweak compiles them into an
app with a mock of Spotify's context menu sheet over a player that plays a local file, runs it, and saves
a screenshot at each step into `build/sim/shots/`. The script taps Edit info, which closes the menu and
brings up the editor sheet. Then it types a name and picks a cover (neither is stored before Save),
saves, opens the editor again, restores the file's info and saves, and last tries to swipe away
unsaved changes, which must ask first. Each step logs `PASS` or `FAIL`. `large` runs it once at the
largest accessibility text size, where each label goes above its field, and sets the size back.

    THEOS=$HOME/theos sim/build-sim.sh <udid> [large]

It does not cover the pickers themselves, the keyboard over the sheet, or Spotify's own menu closing.
