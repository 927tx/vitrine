---
name: phone-check
description: >
  Install a Vitrine build on the paired iPhone and check it there: relaunch, drive it with the phone driver,
  take screenshots, read the view tree and stream the log. Use whenever a change has to be seen or measured
  on the phone, or the user reports something on the phone that needs evidence.
---

# Checking a build on the phone

Values that belong to one person's phone live in `.phone.env` at the repo root (gitignored; copy
`.phone.env.example`). Load them first:

    set -a; . ./.phone.env; set +a    # PHONE_UDID, PHONE_HOST, APP_BUNDLE

## Install

- `make quick` rebuilds only the tweak and installs it in seconds. It needs a full build with FLEX first:
  `scripts/pipeline.sh ipa/Spotify-9.1.78.ipa`, then `make quick`.
- The full build fails inside the sandbox at the App Intents step ("Exception during writing compiled
  data"); run it outside the sandbox.
- `make quick` refuses when the extension, a plist or an icon changed since the full build. Run the full
  build again.
- An install quits the app. Relaunch it and wait for the driver:

      xcrun devicectl device process launch --terminate-existing --device "$PHONE_UDID" "$APP_BUNDLE"
      for i in $(seq 1 15); do sleep 2; scripts/phone.py state >/dev/null 2>&1 && break; done

- After a version change, What's New covers the screen. Close it with `scripts/phone.py tap --text Continue`.

## Drive

`scripts/phone.py` (its header lists every command) talks to the driver in FLEX builds. Over Wi-Fi it
needs `PHONE_HOST` and the token the app logs at launch, which it reads from the log file below.

- Check `scripts/phone.py state` before anything else. Its `top` and `presented` say what is on screen.
- `settings.page` finds only rows on screen. Scroll first. After two failed lookups, stop and ask the
  user to open the page instead of probing further.
- A swipe that only sets `contentOffset` (`scroll`) does not trigger scroll-driven behavior like the tab
  bar's minimize. Use `swipe` with a duration for that.

## Screenshots

The driver's `screenshot` can come back blank. Take them through the tunnel instead, which needs
`sudo pymobiledevice3 remote tunneld` running (the user starts it):

    uvx pymobiledevice3 developer dvt screenshot --tunnel "$PHONE_UDID" "$TMPDIR/shot.png"
    uv run -q --no-project --with pillow python -c "from PIL import Image; im=Image.open('$TMPDIR/shot.png'); w,h=im.size; im.crop((0,int(h*.8),w,h)).save('$TMPDIR/crop.png')"

Read the cropped file with the Read tool. A full-height image is hard to judge; crop to the part in question.

Privacy: a tunnel screenshot captures whatever is on screen. Check `scripts/phone.py state` first, and do
not take one while the user is in another app.

## Log

- `scripts/phone.py log` holds only the latest lines of the current launch. A background screen dump
  floods it, and every relaunch starts it over. For anything across a relaunch or a lock, stream the log
  instead, in the background:

      uvx pymobiledevice3 syslog live --tunnel "$PHONE_UDID" -m '[spotifyglass]' >> /tmp/claude-501/device.log 2>&1

  `scripts/phone.py` reads the Wi-Fi token from that file. `idevicesyslog -n` often cannot find the phone
  over Wi-Fi.
- Grep the file for the feature's log prefix (`lock lyrics:`, `sing:`, `redesign home:`). When a feature
  says nothing about why it did nothing, add one log line per track or per change and rebuild, rather than
  guessing.

## View tree

`scripts/phone.py tree` prints the visible screen's tree as indented text with frames, `hidden`, `a=` (alpha)
and `clips`. To see a view's ancestors, walk up by indentation:

    n=$(grep -n 'SGRBarText' tree.txt | head -1 | cut -d: -f1)
    awk -v n=$n 'NR<=n {match($0,/^ */); d[NR]=RLENGTH; l[NR]=$0} END{w=d[n]; for(i=n;i>0;i--) if(i==n||d[i]<w){print l[i]; w=d[i]}}' tree.txt

Capture the tree in the exact state being judged. A tree taken after another gesture describes a different
layout.

## Before blaming the code

- Spotify playing on another device through Connect (a laptop or speaker glyph on the bar) leaves the phone
  a remote. The lock screen's full-screen artwork and anything that needs local audio do nothing then.
- `sing: the iPhone is hot` means Karaoke holds back on purpose.
- FLEX's toolbar can cover the top of the screen. The user closes it with its ✕.
- A log line on a path that runs per event, per packet or per tick floods the in-app log (it pushed every
  other line out at about fifty a second) and costs battery for every user. Log the first few of a launch
  and a count once a minute, and take debug lines out or cap them before committing.
- Say what the phone showed and what it did not. A build that compiled is not a check on the phone.
