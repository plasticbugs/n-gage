# N-Gage for Analogue Pocket — 1.0.0

The first full release. It boots the Nokia N-Gage's own firmware on the
Pocket and runs games, the 3D ones about 1.7 times as smoothly as the
alphas did.

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

**From any alpha,** copy the whole zip over: both the bitstream and
`ngvm.bin` have changed. Your `sym.rom` and `.img` files are not in it.

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

## New since 0.3.1-alpha

- **Faster, most of all in 3D.** In a simulation of the Pocket's hardware,
  Virtua Cop in play draws about 1.7 times as many screens a second as
  with 0.3.1-alpha (12.5 against 7.5). It runs 43% more instructions a
  second, and its first level loads well before 0.3.1-alpha's has. That
  was measured on a build just before this one; over the game's first
  25 s, this one draws 6% more screens again. What changed:
  - the CPU runs at 80 MHz, on a clock of its own (73.85 MHz before);
  - the instruction and data caches are 64 KB each (16 KB before), and a
    store that misses no longer waits for its line;
  - branch prediction has twice the entries and predicts returns made by
    a load (POP with pc), and a multiply holds the pipeline a cycle less;
  - the memory controller sends a burst's writes one a clock, starts the
    next burst as soon as the last one's data is in, and puts the CPU's
    requests on the bus sooner;
  - the kernel's scheduler and its most frequent calls take less time.
- **The on-screen keypad** (above), so that games can be given numbers
  and the keys the buttons do not have.

## What to expect

- **Seen on a Pocket:** with this build, Virtua Cop, SSX: Out of Bounds
  and Puzzle Bobble VS play. With 0.3.1-alpha's build, The Elder Scrolls
  Travels: Shadowkey and The Sims Bustin' Out play, and Call of Duty
  plays slowly; with 0.3.0-alpha's, Pocket Kingdom plays well. With
  0.2.0-alpha's, Atari Masterpieces Vol. 1 and 2, Rayman 3 and The Roots
  play well. On the builds before it, Colin McRae Rally 2005 plays
  perfectly, Tony Hawk's Pro Skater and Ghost Recon play well, and
  Requiem of Hell starts after a long pause. Sonic N played on
  0.1.0-alpha. The games not named for this build have not been reported
  on it yet.
- **The on-screen keypad** has been checked in simulation (every key
  presses its own, and nothing else reaches the game), not yet on a
  Pocket.
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
- The Analogizer adapter is supported but has not been tried on one.

## This build

| file | md5 |
|---|---|
| `Cores/plasticbugs.ngage/bitstream.rbf_r` | `0c44e9e693b3c62dfbccbd30da78328f` |
| `Assets/ngage/common/ngvm.bin` | `4ef9e13431949931c2af713441108b44` |

CPU at 80 MHz. `docs/bringup.md` in the source says what each screen
should look like and when, and what to report if it does not.
