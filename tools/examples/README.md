# Worked examples

Three tools every core needs and only you can finish, because each one names
the board's own regions, chips and state format. These are one shipped core's
versions (Master of Weapon, Taito B System), kept as patterns: adapting one is
quicker and safer than starting from nothing, and none of them will run here
unchanged.

| file | what to make of it |
|---|---|
| `verify_rom.py` | de-interleaves the built ROM image and compares every region against the bytes MAME hands the chips. Run this before trusting any MRA `map=` attribute — reasoning about interleaves is how people lose a day. |
| `dump_state.lua` | dumps one frame of machine state from MAME — VRAM, sprite RAM, scroll, control registers, palette, and MAME's own pixels — as the frozen state a video bench loads. Note the frame alignment it documents: the pixels in dump N were drawn from tilemaps of N−1 and sprites of N−2. Yours will differ; measure it rather than assuming. |
| `idx2png.py`, `diff_index.py` | the RTL bench writes palette **indices**, not colours, so a difference cannot be hidden by two indices resolving to the same colour. Diff indices, render to PNG only for looking at. |

The fourth piece, the reference renderer itself, is not here because it is the
part that is entirely the board's: a Python model of the video hardware,
checked pixel-for-pixel against MAME's own output, which then becomes the
specification the RTL is held to. `METHODOLOGY.md` sections 1, 3 and 4 describe
building one; `tools/diff_frames.py` in this template is the diff it needs.
