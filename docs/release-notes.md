# N-Gage for Analogue Pocket — 1.3.0

A feature release:

- **Games larger than 32 MB.** A game's card can now hold up to 64 MB,
  which every N-Gage game fits. **Pathway to Glory** (59 MB), too large
  for every earlier release, runs on a Pocket;
- **Add N-Gage games.html** and `mkdrive.py` build those cards. A game
  that fits in 32 MB gets the same card as before, byte for byte, so the
  cards you have already made still work.

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

**From 1.2.0,** copy the whole zip over: the bitstream, `ngvm.bin`,
`mkdrive.py` and `Add N-Gage games.html` have changed. Your `sym.rom`,
`.img` and `.sav` files are not in it, and your menu settings are kept.

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

The core's menu has a slider for each of A, B, X, Y, L and R: at 0 to 9
the button is that digit key of the phone, at 10 it is as in the table.

**The on-screen keypad** is for every key the buttons do not reach.
Press Select and R together and the phone's keypad comes up over the
bottom of the picture: the soft keys, C, 0 to 9, * and #. The d-pad moves
the highlight, A or B presses the key for as long as you hold it, and Y
moves the keypad to the top of the screen and back. Select and R together
put it away. While it is up, the game sees only the keys it presses.

## New since 1.2.0

- **Games larger than 32 MB.** The core's drive is 32 MB, all of the
  Pocket's CRAM. A larger card now works: the Pocket loads the whole
  image, the core keeps its first 32 MB, and the rest is read from the SD
  card, 64 KB at a time, as the game asks for it. Most of those reads come
  as the game starts. Of the retail games, Pathway to Glory and Pathway to
  Glory: Ikusa Islands need this. Glimmerati is larger than 32 MB too, but
  its copy protection checks the memory card, so it does not run.
  A game that fits in 32 MB reads nothing more and runs as on 1.2.0.
- **If one of those reads fails,** the core stops the game and fills the
  screen: **blue** if the Pocket never answered, **red with white bands**
  if it answered with an error (the number of bands is the error code).
  Note which, then quit the core. Neither has been seen on a Pocket.
- **`mkdrive.py` and Add N-Gage games.html** make a card larger than
  32 MB only when the game's files do not fit in 32 MB, up to 64 MB.

## What to expect

- **This build** was tried on a Pocket before release: its tester
  reported that Pathway to Glory runs, the first game over 32 MB on a
  Pocket. How far it was played, how long it took to load and whether it
  saved were not said. Pathway to Glory: Ikusa Islands has been checked
  only in simulation. Games that fit in 32 MB were not tried again on this
  build; in simulation, Sonic N draws the same screens as on 1.2.0.
  Saves now share the Pocket's bridge with the new reads: in simulation
  every save is written back whole, but saves have not been tried again
  on a Pocket. The Analogizer's output is unchanged from 1.2.0.
- **Seen on a Pocket:** with 1.2.0, saves work. With 1.0.0, Virtua Cop,
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
  stops Asphalt Urban GT 2, Glimmerati, Warhammer 40,000: Glory in Death
  and One: the card here is an image, with nothing behind it to identify.
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
| `Cores/plasticbugs.ngage/bitstream.rbf_r` | `408035668fbf78884423721d594088fa` |
| `Assets/ngage/common/ngvm.bin` | `768326c5b49c57c7c4e5183f1aa6db68` |

CPU at 80 MHz. `docs/bringup.md` in the source says what each screen
should look like and when, and what to report if it does not.
