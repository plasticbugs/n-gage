# N-Gage for Analogue Pocket — alpha

An early test release. It boots the Nokia N-Gage's own firmware on the
Pocket and runs games, but slowly, and much of it is untested on hardware.

This core does not rebuild the phone's board. It runs **NGVM**, a small
machine with just enough of an ARM phone for the Symbian user side of your
own phone's firmware to run unchanged. The CPU, an ARMv4T, is gateware; a
small kernel (`ngvm.bin`) stands in for the phone's.

**No firmware or games are included.** You need your own N-Gage's firmware
dump and your own games.

## Install

1. Unzip onto the SD card root, keeping the folders.
2. Into `Assets/ngage/common/`, next to `ngvm.bin`, put:
   - `sym.rom`: your N-Gage's firmware, dumped from your phone (about 18 MB);
   - one `.img` per game, built from the game's files with the builder in
     this zip (Python 3 only):

     ```sh
     python3 mkdrive.py --from vcop.zip --out vcop.img
     ```

   The game list (`Assets/ngage/plasticbugs.ngage/*.json`) names the `.img`
   each game expects. Add a JSON there for any other game.
3. Loading takes a while: about 35 MB go through the Pocket's loader, and
   the screen stays black until it is done. The phone then boots as it
   would, Nokia logo first.

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

## What to expect

- **Seen on a Pocket:** Sonic N, from boot into gameplay with sound, on
  the build before this one. This build has run games on the Pocket too.
  What it was made to fix (a picture that combed in motion, late sound)
  is not yet confirmed there.
- **Tested in simulation only:** Virtua Cop reaches its title, and in the
  reference emulator six of the seven games tried reach their menus or
  play (Bomberman, Puyo Pop, Puzzle Bobble VS, Snakes, Sonic N, Super
  Monkey Ball, Virtua Cop).
- **Slow.** The CPU delivers about 19–25 million instructions a second,
  where the phone managed roughly 45–50. The 3D games run at a lower frame
  rate than on the phone.
- **Sound** lags the picture by 32–64 ms.

## Known problems

- **Leave Menu → SDRAM fast reads off.** It makes the games crash at once.
- The game keeps running behind the Pocket's menu (no pause).
- No saving, sleep or link port.
- Key clicks and the phone's tone player are silent. Game music and effects
  play.
- Snakes' multiplayer needs Bluetooth and cannot start.
- The Analogizer adapter is supported but has not been tried on one.

## This build

| file | md5 |
|---|---|
| `Cores/plasticbugs.ngage/bitstream.rbf_r` | `42a6ceb0fc00f8e8a03dc8d806bd09cb` |
| `Assets/ngage/common/ngvm.bin` | `c4369fba680bae31d19806a044f4d91c` |

CPU at 73.85 MHz. `docs/bringup.md` in the source says what each screen
should look like and when, and what to report if it does not.
