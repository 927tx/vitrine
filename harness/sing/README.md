# Sing harness

Three parts: the separator and the engine on the Mac, Sing end to end in the simulator, and the mic button.

## The separator and the engine on the Mac (`main.m`)

Sing's separator and engine (`tweak/Sources/Shared/Sing/SGSingSeparator.m`, `SGSingEngine.m`) as the tweak
compiles them, on the Mac, over the voice model as the app downloads it (a `separator.mlmodelc` folder of the five
files from https://huggingface.co/My-Name-Is-Jeff/vitrine-sing, a mirror of Darkkos/spoti-sing, MIT). Each check prints a line:

- the STFT: a cosine's peak bin at torch.stft's size (the amplitude times the Hann window's sum over two), noise
  through the STFT and back unchanged, its edges included;
- the model: its input and output shapes, the plan Core ML makes for the compute units asked for (how many
  operations go to the CPU, the GPU and the Neural Engine), the time a two second window takes, and a voice mixed
  over synthetic chords taken apart: the vocals found scored against the voice, beside the mix's own score;
- the engine: the mix pulled through `SGSingEngineRender` in buffers of 1024 on a thread that keeps real time,
  with Sing on from the start: the mix plays dry while the lead fills, then exactly the mix less the vocals the
  offline pass finds, the lead given back after Sing is switched off and the mix playing on where it was, the
  top of the slider playing the vocals alone, a flush dropping the lead, and no allocation on the render thread
  (`malloc_logger`);
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
    ./build.sh && build/sing spatial                                                         (spatial voice alone)

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
settles at 2.84 s (a window plus 1.5 times the model's time and a quarter second).

Not measured: the iPhone. Its GPU is slower than the M4's, and a window must take under 1.5 s (the hop) for the
vocals to keep up; when they do not, what plays is dry until they catch up.

## Sing end to end in the simulator (`sim/main.m`)

The voice model downloaded from Hugging Face by `SGSingModel.m` and checked file by file, loaded by `Sing.x`, and
Spotify's audio chain rebuilt with real units (a converter fed by a render callback, a mixer, RemoteIO, wired with
MakeConnection) with `SpeedPitch.x` and `Sing.x` compiled in (logos, internal generator). The harness is the main
executable, so the rebound imports take as in Spotify and Sing's stage runs in Speed and pitch's chain. The
decoder hands over the voice over the chords; a mock SPTPlayerState computes -position the way Spotify's does
and a mock SPTEsperantoPlayer moves the decoder on seekTo:. A render notify on RemoteIO records what plays.
The script turns Sing on at the vocals' 0, plays, seeks to 5 s at 20 s, and turns Sing off at 30 s; it checks the
download, the model loading, the position Spotify shows against what is heard, the seek's result handed back and
the lead dropped, the vocals down again after it, the lead given back, and what played against the chords alone.

    THEOS=$HOME/theos VOICE=speech.aiff ./build-sim.sh
    xcrun simctl install <udid> build/sim/SingHarness.app
    xcrun simctl launch --console-pty <udid> com.vojta.singharness

2026-10-05, iPhone 17 Pro simulator, iOS 27: the four small files came in from Hugging Face and were checked and
kept; the weights reached 52% before the run was stopped, and were then put in the staging folder from a copy
checked on the Mac, so the move into place ran but the weights' own check in the app did not. The model loads in
1.6-2.1 s. The decoder is drained at 2x until 3.75 s ahead, then at 1x; the position Spotify shows is what is
heard to the hundredth (13.98 s against 13.98 s, with 19.98 s decoded); the seek hands back its result and drops
the 6 s held ahead; switched off, the decoder is drained at 0.5x until the lead is given back. The simulator runs
Core ML on the CPU, 15 s a window, so Sing reads Too slow there and the three vocals checks are skipped: the Mac
harness is where they pass.

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
