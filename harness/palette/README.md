# Palette check

    ./build.sh && build/palette-check

runs `Redesigned/Kit/SGRPalette.m` on the Mac (as Mac Catalyst, for UIKit): a blue cover with a pale border along
its foot, read once by its bottom edge (the player's field) and once by its main colour (a playlist, album or
artist page, `mainColor`). The edge has to come out grey and the main colour blue. It prints PASS or FAIL; the exit
status is the number of failures.
