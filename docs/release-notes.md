# N-Gage for Analogue Pocket — 1.1.0

A feature release for the Analogizer, with one game fixed:

- **TATE** sends the CRT the picture turned a quarter turn, for a tube
  stood on its side;
- the Analogizer's picture is now **centred on a CRT**, with nothing lost
  at the bottom;
- **Rifts: Promise of Power** no longer stops on a black screen after its
  intro cutscenes.

The core boots the Nokia N-Gage's own firmware on the Pocket and runs
games.

This core does not rebuild the phone's board. It runs **NGVM**, a small
machine with just enough of an ARM phone for the Symbian user side of your
own phone's firmware to run unchanged. The CPU, an ARMv4T, is gateware; a
small kernel (`ngvm.bin`) stands in for the phone's.

**No firmware or games are included.** You need your own N-Gage's firmware
dump and your own games.

## Install

1. Unzip onto the SD card root, keeping the folders.
2. Into `Assets/ngage/common/`, next to `ngvm.bin`, put:
   - `sym.rom`: the N-Gage's firmware (the "BIOS"), about 18 MB. Dump it
     from your own phone. A compatible one is `bios/Nokia/N-Gage/SYM.ROM`
     in the [retrobios](https://github.com/Abdess/retrobios) repository on
     GitHub: the firmware this core was tested on, 18,612,224 bytes, md5
     `64a95a4a884cf4cc15a566b856603193`. Rename it to `sym.rom`, in lower
     case;
   - one `.img` per game, built from the game's files with the builder in
     this zip (Python 3 only):

     ```sh
     python3 mkdrive.py --from vcop.zip --out vcop.img
     ```

   The game list (`Assets/ngage/plasticbugs.ngage/*.json`) names the `.img`
   each game expects. Add a JSON there for any other game.
3. Loading takes a while: up to about 50 MB go through the Pocket's loader,
   and the screen stays black until it is done. The phone then boots as it
   would, Nokia logo first.

**From 1.0.0 or any alpha,** copy the whole zip over: both the bitstream
and `ngvm.bin` have changed. Your `sym.rom` and `.img` files are not in
it, and your menu settings are kept.

**Rebuild your `.img` files with this zip's `mkdrive.py`** if you made them
for 0.1.0-alpha and the game is larger than 24 MB, or is Tomb Raider, Tony
Hawk's Pro Skater or Pandemonium.

## Controls

| Pocket | phone |
|---|---|
| d-pad | arrows |
| A / B | 5 / 7 |
| X | OK |
| Y | 9 |
| L / R | the soft keys |
| Select | # |
| Start | OK |
| **Select + R** | the on-screen keypad, and put it away |

The core's menu has a slider for each of A, B, X, Y, L and R: at 0 to 9
the button is that digit key of the phone, at 10 it is as in the table.

**The on-screen keypad** is for every key the buttons do not reach.
Press Select and R together and the phone's keypad comes up over the
bottom of the picture: the soft keys, C, 0 to 9, * and #. The d-pad moves
the highlight, A or B presses the key for as long as you hold it, and Y
moves the keypad to the top of the screen and back. Select and R together
put it away. While it is up, the game sees only the keys it presses.

## New since 1.0.0

- **TATE on the Analogizer.** The N-Gage's screen is taller than it is
  wide, so on a CRT stood on its side the picture can fill the tube's
  height. The "Analogizer" menu has four more options:
  - "On, TATE CW" for a tube turned clockwise (its top to the right);
  - "On, TATE CCW" for one turned anticlockwise;
  - each of those again with "Pocket off".

  The CRT gets one line per column of the picture, 176 lines of 208
  dots, at 15.71 kHz and 59.95 Hz. The Pocket's own screen stays
  upright. The on-screen keypad turns with the picture.
- **The Analogizer's picture is centred on a CRT.** On 1.0.0 vertical
  sync came 3 lines after the picture, so a CRT lost the picture's
  bottom lines in its overscan, and V Position could move it only 2
  lines. The picture now sits 13 lines higher, its middle where an NES's
  is, and V Position moves it from 16 lines up to 12 down.
- **Rifts: Promise of Power** stopped on a black screen at the end of its
  story cutscenes. The game reads one row above a bitmap of its own,
  where the phone would have had other bitmaps; the kernel now keeps a
  blank page there.

## What to expect

- **This build** was tried on a Pocket before release and reported as
  great by its tester, who uses an Analogizer and a CRT.
- **Seen on a Pocket:** with 1.0.0, Virtua Cop, SSX: Out of Bounds and
  Puzzle Bobble VS play. With 0.3.1-alpha's build, The Elder Scrolls
  Travels: Shadowkey and The Sims Bustin' Out play, and Call of Duty
  plays slowly; with 0.3.0-alpha's, Pocket Kingdom plays well. With
  0.2.0-alpha's, Atari Masterpieces Vol. 1 and 2, Rayman 3 and The Roots
  play well. On the builds before it, Colin McRae Rally 2005 plays
  perfectly, Tony Hawk's Pro Skater and Ghost Recon play well, and
  Requiem of Hell starts after a long pause. Sonic N played on
  0.1.0-alpha. The games not named for 1.0.0 have not been reported on
  it or on this build yet.
- **The on-screen keypad** has been checked in simulation (every key
  presses its own, and nothing else reaches the game), and has not been
  reported on from a Pocket.
- **Tested in the reference emulator only:** of 54 games, 46 run for
  45 s past the boot logos with a picture and sound, with A and X pressed
  a few times from 30 s. Puzzle Bobble VS and Pandemonium reach their
  menus too and start their sound later.
- **Not yet compared with the phone.** On the alphas, 3D games ran below
  the phone's frame rate; the heaviest may still.
- **Sound** lags the picture by 32–64 ms.
- **Games take some 0.3 s longer to start:** the phone's connection
  settings are written at boot.

## Known problems

- Reported from a Pocket with 0.3.0-alpha, and not reported on this
  build: Puzzle Bobble VS has no sound, though the game itself has sound.
- Reported from a Pocket with 0.2.0-alpha, and not yet tried on this
  build, which is faster:
  - X-Men Legends II returns to the N-Gage logo partway through its
    attract mode. It needs a faster CPU: in the reference emulator it
    plays at 45 MIPS, and at 0.2.0-alpha's speed it starved its own view
    events until the phone's view server gave up on it.
  - Puyo Pop has no music in the game; its attract mode and intro have
    sound. It fell behind its music stream at 0.2.0-alpha's speed and
    dropped it for good.
- Copy protection that checks the memory card the game was installed on
  stops Asphalt Urban GT 2, Warhammer 40,000: Glory in Death and One:
  the card here is an image, with nothing behind it to identify.
- In the reference emulator, not yet tried on a Pocket: Civilization and
  Splinter Cell: Chaos Theory stop during startup, and the Payload trial
  does not get past its first screens.
- The game keeps running behind the Pocket's menu (no pause).
- Saves last until the Pocket is switched off: nothing is written back to
  the SD card. No sleep or link port.
- Key clicks and the phone's tone player are silent. Game music and effects
  play.
- Bluetooth multiplayer (Snakes and others) has no radio and cannot start.

## This build

| file | md5 |
|---|---|
| `Cores/plasticbugs.ngage/bitstream.rbf_r` | `b7b65bb3d179257456d0910545397c5a` |
| `Assets/ngage/common/ngvm.bin` | `9e7b7a4eda38f57a9d22c299288391cf` |

CPU at 80 MHz. `docs/bringup.md` in the source says what each screen
should look like and when, and what to report if it does not.
