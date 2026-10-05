# Lyrics clip harness

`SGLyricsClip.m`, the clips the lock screen shows a line of lyrics in, run on the Mac. It renders a
short line, a long one, a CJK one, a break (the next line only), the last line and an empty clip, each
as a Still and as Animated, over a stand-in cover or the image given. Every file is read back with
AVFoundation and checked: its length (2 s for a still, 4 s for an animated loop), its 3:4 size, H.264,
how many frames it holds (1 or 96), white words in the middle band and none under the clock or the
controls, and the words the same at the end as at the start. It prints how long each clip took to
write. The first frame of each clip is saved next to it as a PNG.

    ./build.sh && build/lyrics-clip [cover.jpg]

The clips land in `build/clips/`.
