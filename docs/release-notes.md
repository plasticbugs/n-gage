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

**From 0.2.0-alpha,** only `ngvm.bin` has changed: the bitstream is the
same. Copying the whole zip over is fine too; your `sym.rom` and `.img`
files are not in it.

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

## New since 0.2.0-alpha

The phone's software side only; the gateware is 0.2.0-alpha's.

- **The Sims Bustin' Out** gets past its loading screen and plays. It
  saves from near the top of its stack and copies past it; a phone has
  memory there, and now so does this one.
- **Call of Duty** plays, slowly. It needed three things a phone has: a
  message server that stays up, a modem record in the phone's connection
  settings, and an identity for the phone and its SIM.
- **Pocket Kingdom: Own the World** plays. It asks for the phone's and
  the SIM's identity, and waited for ever for an answer.
- **The phone has a made-up identity:** IMEI `001010124628312` and IMSI
  `001010123456789`, from the number ranges kept for test equipment, so
  they belong to no real phone or SIM. Games that read them get these.
  They cannot stand in for a particular phone: a game tied to the phone it
  was installed on will not accept them.
- **The Elder Scrolls Travels: Shadowkey** now gets past the N-Gage logo
  to its own Nokia copyright screen (it then stops; below).
- **Asphalt Urban GT 2** gets further: it decrypts its own code, which used
  to fail. It then stops at its copy protection (below).

## What to expect

- **Seen on a Pocket:** with this build, The Sims Bustin' Out and Pocket
  Kingdom play well, and Call of Duty plays slowly. With 0.2.0-alpha's
  build, which this one changes only for the games above: Atari
  Masterpieces Vol. 1 and 2, Rayman 3 and The Roots play well; on the
  builds before it, Colin McRae Rally 2005 plays perfectly, Tony Hawk's
  Pro Skater and Ghost Recon play well, and Requiem of Hell starts after
  a long pause. Sonic N played on 0.1.0-alpha.
- **Tested in the reference emulator only:** of 54 games, 46 run for
  45 s past the boot logos with a picture and sound (42 with 0.2.0-alpha),
  with A and X pressed a few times from 30 s. Puzzle Bobble VS and
  Pandemonium reach their menus too and start their sound later.
- **Slower than the phone.** 3D games run at a lower frame rate than on
  the phone, and Puyo Pop too slowly to keep its music (below).
- **Sound** lags the picture by 32–64 ms.
- **Games take some 0.3 s longer to start:** the phone's connection
  settings are written at boot.

## Known problems

- Reported from a Pocket with this build:
  - The Elder Scrolls Travels: Shadowkey returns to the N-Gage logo after
    its Nokia copyright screen.
  - Puzzle Bobble VS: sound is still missing, though the game itself has
    sound.
- Reported from a Pocket with 0.2.0-alpha, and unchanged here:
  - X-Men Legends II returns to the N-Gage logo partway through its
    attract mode. It needs a faster CPU: in the reference emulator it
    plays at 45 MIPS, and at this core's speed it starves its own view
    events until the phone's view server gives up on it.
  - Puyo Pop has no music in the game; its attract mode and intro have
    sound. It falls behind its music stream at this CPU's speed and
    drops it for good.
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
| `Cores/plasticbugs.ngage/bitstream.rbf_r` | `3abc5ef3b671449903455e69d1784251` |
| `Assets/ngage/common/ngvm.bin` | `273a9af95aa31434479aadba9b8d106e` |

CPU at 73.85 MHz. `docs/bringup.md` in the source says what each screen
should look like and when, and what to report if it does not.
