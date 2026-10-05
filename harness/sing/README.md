# Sing harness

Three parts: the separator and the engine on the Mac, Sing end to end in the simulator, and the mic button.

## The separator and the engine on the Mac (`main.m`)

Sing's loader, separator and engine (`tweak/Sources/Shared/Sing/SGSingLoader.m`, `SGSingSeparator.m`,
`SGSingEngine.m`) as the tweak compiles them, their log lines printed through `shim/Core/SGLog.h`, on the Mac, over the voice model as the app downloads it (a `separator.mlmodelc` folder of the five
files from https://huggingface.co/My-Name-Is-Jeff/vitrine-sing, a mirror of Darkkos/spoti-sing, MIT). Each check prints a line:

- the STFT: a cosine's peak bin at torch.stft's size (the amplitude times the Hann window's sum over two), noise
  through the STFT and back unchanged, its edges included;
- the loader: a load past a deadline of 0.2 s abandoned and Sing Failed, Failed kept until the mic goes off and on,
  then a fresh load beside the abandoned one with a second want joining it, the CPU copy loaded and warmed with a
  window of silence, the abandoned load let go when it comes back (the separator stays the fresh one's), the faster
  copy (the units asked for; `cpu` for none) loaded beside it, the copies kept over a quick off and on and dropped
  after the time kept, and a load purged on its way let go;
- the model: its input and output shapes, the plan Core ML makes for the compute units asked for (how many
  operations go to the CPU, the GPU and the Neural Engine), the time a two second window takes, and a voice mixed
  over synthetic chords taken apart: the vocals found scored against the voice, beside the mix's own score;
- the engine: the mix pulled through `SGSingEngineRender` in buffers of 1024 on a thread that keeps real time,
  with Sing on from the start: the mix plays dry while the lead fills, then exactly the mix less the vocals the
  offline pass finds, the lead kept after Sing is switched off and the mix playing on where it was, nothing skipped, the
  top of the slider playing the vocals alone, a flush dropping the lead, and no allocation on the render thread
  (`malloc_logger`);
- the lead, without the model: the lead reported is the frames pulled and not played, to the frame; held (the heat,
  resting), given up or switched off, it is kept and played on as it is, every frame in order and none built; a flush
  (a pause, a seek) drops it at once and the next frame pulled plays next; it is built again when it separates; and
  the lead to take off a position Spotify counted at a moment is the lead held then, less what was dropped since;
- spatial voice, without the model (a separator that hands each window back whole as vocals, so what plays is the
  vocals placed): a 440 Hz tone at level 1 plays exactly as it came straight ahead; set 90 degrees right, the right
  ear has it 7.75 dB louder (the narrowed pan's 7.66 and the far ear's low-pass) at the same power, and the left ear
  31 frames later (the 28.7 frames around a head and the low-pass's own lag); 90 degrees left mirrors it; back ahead
  it is exact again; no step from one frame to the next is larger than the tone's own at the louder gain, so no
  turn clicks; and nothing is allocated on the render thread;
- the front spatial voice holds the voice off (SGSpatialVoiceAngle, shared with the Spatial voice page's preview),
  fed at 25 Hz: a head turned 60 degrees left has the voice 60 degrees right, and 20 s on 22 (the front's 1/e);
  yaw wrapping across 180 degrees moves the voice by the 1 degree it turned; a gap of 2 s starts it ahead again.

The voice is macOS's own speech, `say -o speech.aiff "..."` (any file ExtAudioFile reads will do), repeated a
second apart over 30 seconds.

    ./build.sh && build/sing <separator.mlmodelc> <voice> <out dir> [all|cpu|gpu|ane]
    ./build.sh thread && build/sing-thread <separator.mlmodelc> <voice> <out dir> gpu     (ThreadSanitizer)
    ./build.sh && build/sing spatial                                        (the lead, spatial voice and falling behind)

The out dir gets `mix.wav`, `vocals.wav`, `accompaniment.wav`, `engine.wav` (what played) and `spatial.wav` (the
tone turned; the temporary folder's with `spatial` alone).

2026-10-05, spatial voice: everything passes, under ThreadSanitizer too. The full run passes with it; one run on a
Mac loaded far past its cores had the model fall behind (790 ms a window, 3.6 s played dry) and failed the two
vocals scores; the harness built from before spatial voice passed right after it, and this one on the next run.

2026-10-06, the front: `build/sing spatial` passes with its four checks.

2026-10-05, a MacBook with an M4, macOS 27: everything passes under `gpu` and under ThreadSanitizer.

| compute units | Core ML's plan | a window, warm |
|---|---|---|
| `gpu` (CPU and GPU) | 1996 operations on the GPU | 405-525 ms |
| `all` | 1303 on the GPU, 693 on the Neural Engine | 2500 ms |
| `ane` (CPU and Neural Engine) | 1755 on the CPU | 6250 ms |

The model card keeps normalization, attention, softmax and the matrix products in float32, which the Neural
Engine does not run, so splitting the graph between it and the GPU costs more than it saves on the Mac; Sing asks
for the CPU and GPU unless the Sing page's Runs on says otherwise (`SGKeySingComputeUnits`). The vocals found score 28.1 dB against the voice where the mix scores
7.6 dB, and the mix less them 20.5 dB against the chords where the mix scores -7.6 dB. In the engine the lead
settled at 2.84 s (a window plus 1.5 times the model's time and a quarter second); since 2026-10-06 the spare is
0.75 s, for the hysteresis, and the lead settles at 3.4-3.7 s.

2026-10-06, the runtime (a CPU copy first, a faster one beside it): everything passes under `gpu`, and the model-free
checks under ThreadSanitizer, the new checks with them: the loader's cases above; each window on the faster copy in
the foreground and on the CPU's in the background; a window the faster copy fails done again on the CPU's, the faster
copy resting until the app has been in the background; a model that keeps up and then falls behind fading the vocals
out once and giving up after 8 s short of them; a NaN from the model playing as silence; the loudness the Sing page
draws. The Mac was shared with other work and its load average swung between 6 and 830 through the day, so the times
below were each taken when it was low (under 30) and are a guide, not a benchmark:

| copy | load (cold, then from Core ML's cache) | warm-up window of silence | a window, warm |
|---|---|---|---|
| CPU only | 0.5-5.2 s, then 0.0 s | 0.5-2.3 s | 470-480 ms (the first after the copy sat idle: 1.7-3.7 s) |
| GPU (CPU and GPU) | 0.4-3.7 s | 0.6-1.2 s | 450-760 ms |
| GPU and Neural Engine | 0.2-0.7 s | 1.3-1.4 s | 1260-1600 ms |
| Neural Engine (CPU and Neural Engine) | 139.5 s, then 20.5 s | 6.3-18.0 s | 4000-6800 ms |

Footprint, from a probe that loads copies one after the other and keeps them: one copy 1.40-1.50 GB, a second copy
1.07-1.20 GB more, whatever the units. So the loader wants 1.6 GB left to the process before a second copy. A window
of silence took as long as a window of noise.

Not measured: the iPhone. Its GPU is slower than the M4's, and a window must take under 1.5 s (the hop) for the
vocals to keep up; when they do not, what plays is dry until they catch up.

2026-10-06, the lead kept while not separating and taken off by the report's moment: everything passes under `gpu`,
and `spatial` under ThreadSanitizer. The lead was off by 0 frames from what was pulled and not played; held from 8 s
to 12 s it stayed at 2.75 s with every frame played in order; a flush read 0 at once, and a position counted at 1 s
then had -1.73 s taken off (the 1.02 s held then less the 2.75 s dropped).

## Sing end to end in the simulator (`sim/main.m`)

The voice model downloaded from Hugging Face by `SGSingModel.m` and checked file by file, loaded by `Sing.x`, and
Spotify's audio chain rebuilt with real units (a converter fed by a render callback, a mixer, RemoteIO, wired with
MakeConnection) with `SpeedPitch.x` and `Sing.x` compiled in (logos, internal generator). The harness is the main
executable, so the rebound imports take as in Spotify and Sing's stage runs in Speed and pitch's chain. The
decoder hands over the voice over the chords; a mock SPTPlayerState computes -position the way Spotify's does
and a mock SPTEsperantoPlayer moves the decoder on seekTo:. A render notify on RemoteIO records what plays.
The mock player keeps one of three clocks, chosen with `-clock` at launch: `report` (the default) reports when playing
starts, on a seek and on a pause, and its last report runs on by the time; `restamp` hands the lyrics that report
stamped again at every read of the player's state, the same line of the clock; `decoded` reports again every half
second with what the decoder has handed over. The lyrics' position is read from the player's state as the lyrics
read it. The thermal state is the script's. The script turns Sing on at the vocals' 0, plays, taps the lyrics line
at 5 s at 20 s (the lyrics' seek, `SGKaraokeSeek(5000)`, with a lead held), rests at As sung at 27 s and separates
again at 29 s, goes to the thermal state Serious at 31 s and back to Fair at 32 s, stops Sing with a memory warning,
pauses and resumes, and turns it off; it checks the download, the model loading, the lead Sing reports against what
the decoder handed over less what was heard, the position the lyrics read against what is heard at each step (as the
lead fills after a report, a second after the tap, after the seek, resting, held, stopped, paused, resumed), the tap
sending Spotify to the line's 5 s and what is heard a second later being 5 s run on, the lead dropped by the seek,
the lead kept resting, at Serious and stopped, Spotify seeked back to what was heard at the pause with the lead let
go, the song resuming there with nothing skipped, and what played against the chords alone. A pass says Sing.x is
right for that mock's clock, not which clock the iPhone's Spotify keeps: the `sing: clock:` log line says that.

    THEOS=$HOME/theos VOICE=speech.aiff ./build-sim.sh
    xcrun simctl install <udid> build/sim/SingHarness.app
    xcrun simctl launch --console-pty <udid> com.vojta.singharness [-clock report|restamp|decoded]

2026-10-05, iPhone 17 Pro simulator, iOS 27: the four small files came in from Hugging Face and were checked and
kept; the weights reached 52% before the run was stopped, and were then put in the staging folder from a copy
checked on the Mac, so the move into place ran but the weights' own check in the app did not. The model loads in
1.6-2.1 s. The decoder is drained at 2x until 3.75 s ahead, then at 1x; the position Spotify shows is what is
heard to the hundredth (13.98 s against 13.98 s, with 19.98 s decoded); the seek hands back its result and drops
the 6 s held ahead; switched off, the decoder is drained at 0.5x until the lead is given back. The simulator runs
Core ML on the CPU, 15 s a window, so Sing reads Too slow there and the three vocals checks are skipped: the Mac
harness is where they pass.

2026-10-06, iPhone 17 Pro simulator, iOS 27, with the runtime and Shared/Player's music output: the model put in the
app's Application Support beforehand, the CPU copy loads in 4.9 s and warms in 7.2 s, Sing reads Ready 12.7 s after
the mic, and the GPU copy loads beside it (2.8 s, warmed in 14.7 s: the simulator runs Core ML on the CPU). Sing reads
the music's output through SGPlayerWatchMusicOutput (44100 Hz, 2 channels, takes it). The position, the seek and the
lead given back pass; the vocals checks are skipped as before (16 s a window).

2026-10-06, iPhone 17 Pro simulator, iOS 27, reports only on a change: everything passes. At 14 s the position shows
14.06 s against 14.05 s heard, where the lead taken off as it is now would have shown 9.81 s; Sing reads As sung,
Held, too hot and Stopped with the 4.25 s it held played on, the position matching what is heard within 0.01 s; at
Fair the model loads again in 10.3 s with the lead kept; paused, Spotify is seeked back from 32.61 s to 28.38 s (heard:
28.36 s) and the lead let go, and 2.07 s after resuming 30.45 s is heard. The vocals checks are skipped as before.

2026-10-06, the three clocks, iPhone 17 Pro simulator, iOS 27: everything passes under each (26 checks; the vocals
checks skipped as before). The tap at 20 s with 4.25 s held sends Spotify to 5.00 s and a second later 5.98 s is heard
and read. Under `report`, a run with the Mac's load average near 60 read the position 0.17 s off what was heard at
three steps, past the 0.15 s allowed, and passed again at a load of 30: the harness measures what is heard by the
decoder, whose converter pulls ahead by what the load lets it. A line let run on across Sing's own
flushes read the resume after the pause 4.25 s ahead of what was heard (the seek back runs on from the line before it),
so a report after one of Sing's seeks, skips or seeks back always starts a line.

## The download on the Mac (`download/`)

`SGSingModel.m` as the tweak compiles it, built for Mac Catalyst (Sing.h imports UIKit) with `download/shim` standing
in for the mod's core so its log goes to stderr, against Hugging Face. The four small files and a fifth of the weights
come in, the download is stopped (its resume data kept beside the staging folder), and the next download carries the
weights on from there through the checks and the move into place. `CFFIXED_USER_HOME` keeps the 489 MB out of the
Mac's own Application Support.

    download/build.sh && CFFIXED_USER_HOME="$(mktemp -d)" build/download 0.2

2026-10-05, a MacBook with an M4, macOS 27: everything passes. The stop is at 20%, the next download's first bytes
read 21%, the server answers the resumed weights 206 and the whole 488986336 bytes are handed over and checked. An
earlier run lost the network for a few seconds and its three retries failed at once, which is why the session now
waits for connectivity. Not run: an expired resume (the server's signed address lasts a day), which starts the file
over.

## The mic button (`button/`)

`SGRSingButton.m` on a field like the lyrics', in the state the launch line asks for, for screenshots.
`button/sing-stubs.m` answers Sing's calls; the lyrics harness links it too.

    button/build.sh && xcrun simctl install <udid> button/build/SingButtonHarness.app
    xcrun simctl launch <udid> com.vojta.singbuttonharness -state 7 -panel 1 -level 0.4
