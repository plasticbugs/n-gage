# N-Gage for Analogue Pocket — alpha

An early test release. It boots the Nokia N-Gage's own firmware on the
Pocket and runs games, but slower than the phone, and much of it is
untested on hardware.

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

The core's menu has a slider for each of A, B, X, Y, L and R: at 0 to 9
the button is that digit key of the phone, at 10 it is as in the table.

## New since 0.1.0-alpha

- **Faster.** A cache miss now restarts the CPU on the word it missed, and
  a dirty line is written back behind the fill. SDRAM reads at a word a
  clock, which crashed 0.1.0-alpha's games, now capture at the right
  clock and are the default. In simulation of the Pocket's hardware,
  Sonic N's first 40 s run 1,347 million instructions against 1,083
  million in 0.1.0-alpha (+24%), and show 578 frames against 337.
- **Games up to 32 MB** (the whole drive the core has), such as Worms
  World Party.
- **Sound** in Puzzle Bobble VS, which a key click used to silence for good,
  in Puyo Pop's attract mode and intro, and in Tony Hawk's Pro Skater and
  Pandemonium, which never got their audio stream.
  Tomb Raider's menus are silent; it speaks and plays its effects in the
  game.
- **More games start** (seen in the reference emulator): System Rush and
  Xanadu Next, which load a program from the card or ask the phone's state;
  Requiem of Hell, whose mixer runs on an exception; Colin McRae Rally 2005,
  Tomb Raider, Tony Hawk's Pro Skater and Pandemonium, which keep their
  pointers in 24 or 25 bits; Atari Masterpieces Vol. 2 and Rifts: Promise
  of Power, which ask whether the keypad is locked.
- **Atari Masterpieces Vol. 1 and Rayman 3** play: a game's shortest
  timer waits now last at least 1 ms, as the phone's lasted until its next
  tick. Waits that ended at once kept Atari on the N-Gage logo, and threw
  Rayman back to it when a game was started.
- **Ghost Recon** no longer locks up when a new profile is chosen: the
  phone's Bluetooth server now runs, as on a phone. There is still no
  radio behind it.
- **Any digit key on any button**, from the menu.

## What to expect

- **Seen on a Pocket:** with this build, Atari Masterpieces Vol. 1 and 2,
  Rayman 3 and The Roots play well, with no regression seen elsewhere.
  On the builds just before it: Colin McRae Rally 2005 plays perfectly,
  Tony Hawk's Pro Skater and Ghost Recon play well, and Requiem of Hell
  starts after a long pause. Sonic N played on 0.1.0-alpha.
- **Tested in the reference emulator only:** of 54 games, 42 run for
  45 s past the boot logos with a picture and sound, with A and X pressed
  a few times from 30 s. Puzzle Bobble VS and Pandemonium reach their
  menus too and start their sound later.
- **Slower than the phone.** 3D games run at a lower frame rate than on
  the phone, and Puyo Pop too slowly to keep its music (below).
- **Sound** lags the picture by 32–64 ms.

## Known problems

- Reported from a Pocket with this build:
  - Asphalt Urban GT 2 freezes at startup.
  - The Elder Scrolls Travels: Shadowkey stays on the N-Gage logo.
  - The Sims Bustin' Out stalls on its loading screen (the crowd of
    people).
  - X-Men Legends II returns to the N-Gage logo partway through its
    attract mode.
  - Puyo Pop has no music in the game; its attract mode and intro have
    sound. It falls behind its music stream at this CPU's speed and
    drops it for good.
- In the reference emulator, not yet tried on a Pocket: Civilization,
  One and Splinter Cell: Chaos Theory stop during startup, and Call of
  Duty, Pocket Kingdom and the Payload trial do not get past their first
  screens.
- The game keeps running behind the Pocket's menu (no pause).
- Saves last until the Pocket is switched off: nothing is written back to
  the SD card. No sleep or link port.
- Key clicks and the phone's tone player are silent. Game music and effects
  play.
- Bluetooth multiplayer (Snakes and others) has no radio and cannot start.
- Warhammer 40,000: Glory in Death stops at its own splash screen: its copy
  protection checks the phone it runs on.
- The Analogizer adapter is supported but has not been tried on one.

## This build

| file | md5 |
|---|---|
| `Cores/plasticbugs.ngage/bitstream.rbf_r` | `3abc5ef3b671449903455e69d1784251` |
| `Assets/ngage/common/ngvm.bin` | `d8ff20df4fb8a6afbbf7156c702883b1` |

CPU at 73.85 MHz. `docs/bringup.md` in the source says what each screen
should look like and when, and what to report if it does not.
