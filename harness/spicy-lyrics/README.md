# Spicy Lyrics check

`./build.sh` reads made-up responses of the Spicy Lyrics API (a Syllable sync with a duet, a
backing vocal, a split word and a translation; a Line sync with a gap; a Static one) through the real
`SGSpicyLyricsResult` and checks the lines and the credit each one gets, and that a translation is
left out once the Lyrics page asks for a language. It runs on the Mac as a
Mac Catalyst binary, with no simulator and no network.

It does not cover the request itself, the key in the Keychain, or the lines on the lyrics view.
