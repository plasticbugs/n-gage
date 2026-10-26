# N-Gage for Analogue Pocket — 1.4.0

A fix and a feature:

- **Glimmerati** no longer freezes on its "Day 1 The Introduction"
  loading bar. One instruction in its drawing code saves the stack
  pointer along with other registers, and the core's CPU saved the wrong
  value, so the race broke on its first frame;
- **\* and # on a button.** The menu's six key sliders now go up to 12:
  11 is \*, 12 is #. Each slider's name says what its 10, 11 and 12 are;
- **Add N-Gage games.html** now shows which button is which key, and
  what the slider numbers mean.

1.3.0 made games up to 64 MB work, Pathway to Glory (59 MB) among them.

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
   - one `.img` per game, made from the game's files.

   **The easy way** does both. With the SD card in your computer, open
   `Assets/ngage/common/Add N-Gage games.html` from it in Microsoft Edge
   or Google Chrome, on Windows or a Mac. Press "Choose my SD card", pick
   the card's `Assets` folder, then drop your game zips (and `SYM.ROM`)
   on the page. Each game gets a green tick when it is on the card, with
   its entry in the Pocket's menu. A short film on the page shows every
   step. Other browsers download the files for you to copy over.

   Or, with Python 3, the builder in this zip:

   ```sh
   python3 mkdrive.py --from vcop.zip --out vcop.img
   ```

   The game list (`Assets/ngage/plasticbugs.ngage/*.json`) names the `.img`
   and the `.sav` each game uses. The page writes these entries; by hand,
   add a JSON there for any other game.
3. Loading takes a while: up to about 50 MB go through the Pocket's loader
   (about 80 MB for Pathway to Glory), and the screen stays black until it
   is done. The phone then boots as it would, Nokia logo first.

**From 1.3.0 or 1.2.0,** copy the whole zip over: the bitstream,
`ngvm.bin`, the menu and `Add N-Gage games.html` have changed, and from
1.2.0 `mkdrive.py` too. Your `sym.rom`, `.img` and `.sav` files are not in
it, and your menu settings are kept: a key slider stays where you put it.

**From 1.1.0 or earlier,** copy the whole zip over: the game list has
changed too. Your menu settings are kept, except a Shadow Mask setting,
which goes back to Off: choose it again under Screen Effect.

**Games you added to the list yourself** need a save entry, or they all
share one save file, `ngage.sav`. In the game's JSON, after the `.img`
entry, add `{ "id": 4, "filename": "<game>.sav" }`, as the games in this
zip have.

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

**To move a key,** press the Pocket's Analogue button and open Core
Settings: A, B, X, Y, L and R each have a slider, and its number is the
phone key the button presses.

| slider | the button presses |
|---|---|
| 0 to 9 | that digit key |
| 10 | its own key, as in the table above |
| 11 | \* |
| 12 | # |

Each slider's name says it too: `Button A 10=5 11=* 12=#`.

**The on-screen keypad** is for every key the buttons do not reach.
Press Select and R together and the phone's keypad comes up over the
bottom of the picture: the soft keys, C, 0 to 9, * and #. The d-pad moves
the highlight, A or B presses the key for as long as you hold it, and Y
moves the keypad to the top of the screen and back. Select and R together
put it away. While it is up, the game sees only the keys it presses.

## New since 1.3.0

- **Glimmerati's "Day 1" load.** Glimmerati's span drawer opens with
  `STMDB sp!, {r4-r12, sp, lr}` and closes with the matching `LDMIA`. The
  core's CPU stored the stack pointer after moving it rather than before,
  so the stack came back 44 bytes short and the game broke on the race's
  first frame, leaving the loading screen up. ARMv4 leaves this case
  undefined; the CPU now does what the reference emulator does, and
  Glimmerati gets past the load.
- **\* and # on the key sliders**, at 11 and 12. 0 to 10 mean what they
  did, so saved settings carry over.
- **Add N-Gage games.html** has a section on the buttons.

## New in 1.3.0

- **Games larger than 32 MB.** The core's drive is 32 MB, all of the
  Pocket's CRAM. A larger card now works: the Pocket loads the whole
  image, the core keeps its first 32 MB, and the rest is read from the SD
  card, 64 KB at a time, as the game asks for it. Most of those reads come
  as the game starts. Of the retail games, Pathway to Glory and Pathway to
  Glory: Ikusa Islands need this, and so does Glimmerati.
  A game that fits in 32 MB reads nothing more and runs as on 1.2.0.
- **If one of those reads fails,** the core stops the game and fills the
  screen: **blue** if the Pocket never answered, **red with white bands**
  if it answered with an error (the number of bands is the error code).
  Note which, then quit the core. Neither has been seen on a Pocket.
- **`mkdrive.py` and Add N-Gage games.html** make a card larger than
  32 MB only when the game's files do not fit in 32 MB, up to 64 MB.

## What to expect

- **This build** was tried on a Pocket before release: its tester
  confirmed it working after being asked to check that Glimmerati gets
  past the "Day 1" load, that the key sliders show their new names and
  go to 12, and that a button set to 11 gives \* in a game. Which game,
  and how far the race was played, were not said. The build before it,
  the same but for the sliders, got Glimmerati past the load on a Pocket
  too. In simulation the fixed CPU matches the reference emulator
  instruction for instruction: through Glimmerati's load and into the
  race (721 million instructions), over the firmware's boot, and on 40
  random programs. Other games were not tried again on a Pocket with
  this build; the Analogizer's output is unchanged.
- **Seen on a Pocket:** with 1.3.0, Pathway to Glory (59 MB) runs, the
  first game over 32 MB on a Pocket; Pathway to Glory: Ikusa Islands has
  been checked only in simulation. With 1.2.0, saves work. With 1.0.0, Virtua Cop,
  SSX: Out of Bounds and Puzzle Bobble VS play. With 0.3.1-alpha's
  build, The Elder Scrolls Travels: Shadowkey and The Sims Bustin' Out
  play, and Call of Duty plays slowly; with 0.3.0-alpha's, Pocket
  Kingdom plays well. With 0.2.0-alpha's, Atari Masterpieces Vol. 1 and
  2, Rayman 3 and The Roots play well. On the builds before it, Colin
  McRae Rally 2005 plays perfectly, Tony Hawk's Pro Skater and Ghost
  Recon play well, and Requiem of Hell starts after a long pause. Sonic N
  played on 0.1.0-alpha. The games not named for 1.0.0 have not been
  reported on it or on this build yet.
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
  stops some copies of Asphalt Urban GT 2, Glimmerati, Warhammer 40,000:
  Glory in Death and One: the card here is an image, with nothing behind
  it to identify.
- Glimmerati stops at startup once it has a save, before its
  cinematics, with the last picture left on screen (reported from a
  Pocket on this build). In simulation, with the same copy and the same
  save, it asks for the memory card twice, is told there is none, and
  its own code faults milliseconds later; without a save it never asks.
  Deleting `Saves/ngage/plasticbugs.ngage/glimmerati.sav` lets it start
  again and loses its progress, so for now it cannot keep progress from
  one start to the next.
- In the reference emulator, not yet tried on a Pocket: Civilization and
  Splinter Cell: Chaos Theory stop during startup, and the Payload trial
  does not get past its first screens.
- The game keeps running behind the Pocket's menu (no pause).
- No sleep or link port.
- Key clicks and the phone's tone player are silent. Game music and effects
  play.
- Bluetooth multiplayer (Snakes and others) has no radio and cannot start.

## This build

| file | md5 |
|---|---|
| `Cores/plasticbugs.ngage/bitstream.rbf_r` | `749b0353218fc2ce73eea2978dcfc42d` |
| `Assets/ngage/common/ngvm.bin` | `4f1e2825ab85f08888fd1eb847ba2438` |

CPU at 80 MHz. `docs/bringup.md` in the source says what each screen
should look like and when, and what to report if it does not.
