# Speed harness

Spotify's audio chain (AudioUnitDriver2: a converter fed by a render callback, a mixer and RemoteIO, wired
with MakeConnection, slices of 4096) rebuilt with real units in the simulator, with `PlayerSpeedPitch.x`
compiled in: its AudioUnitSetProperty rebinding takes over the mixer-to-output connection exactly as on
the phone (the harness is the main executable), and its SPTPlayerState hook runs on a mock state that
computes -position the way Spotify's does.

    THEOS=$HOME/theos ./build.sh
    xcrun simctl install booted build/SpeedHarness.app
    xcrun simctl launch --console-pty booted com.vojta.speedharness [rate]

The script plays a quiet sine and steps through normal, 1.5x, 1.5x at +3 semitones, 0.75x and back,
logging how fast the converter's callback (the decoder) was drained and how far the state's position is
from the content played. 2026-09-18: drained 1.00x, 1.50x, 1.50x, 0.75x, 1.00x; position within 12 ms.

`rate` sets the output's input side to 48 kHz while it runs, halfway through the 1.5x step, with no new
`AudioOutputUnitStart`. The mod's format listener reads the new format and makes the chain's unit again
(`a unit in the chain for 48000 Hz, 2 channels`); until then a unit made for another rate passes the
sound as it is. 2026-10-05: the unit was made again at 48 kHz at once, with 0 underruns. The drain
figures after the change read about 1.09 times the speed, because the harness's mixer stays at 44.1 kHz
and the output now takes 48 kHz from it.
