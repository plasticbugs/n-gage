# The board

Written from MAME's driver and devices (`ref/mame/`, fetched verbatim — record
the MAME version and the file list here) and from the program ROM itself, **before
any RTL**. Everything the gateware does should be traceable to a line in this
file; when MAME and the ROM disagree, say so here and say which you followed.

## 1. Parts and clocks

| part | type | clock | notes |
|---|---|---|---|
| main CPU | | MHz, from which crystal and divider | |
| sound CPU | | | |
| sound chip(s) | | | output routing, filters, relative levels |
| video chip(s) | | pixel clock, HTOTAL x VTOTAL, refresh in Hz | |
| I/O | | | |

Refresh rate to three decimals. Audio pacing: what sets the music's tempo (a
timer in the sound chip? an interrupt from the video? the main CPU?) — find
out now, METHODOLOGY section 5.3.

## 2. Memory map — main CPU

| range | size | what | R/W | mirrors, byte lanes, wait states |
|---|---|---|---|---|

## 3. Inputs and DIP switches

Bit by bit, with polarity, from MAME's `PORT_START` blocks. Factory DIP
settings, and what each switch does *on this board* — a switch whose effect
the gateware does not implement must not reach the menu.

## 4. Interrupts

Source, level or vector, when in the frame (line number), how acknowledged,
and what MAME's `HOLD_LINE`/`ASSERT_LINE` choice means for the hardware.

## 5. Main CPU to sound CPU

The mailbox or latch, its handshake, its side effects on read.

## 6. Sound board

Memory map, banking, the chip's ports, mixing levels as MAME routes them.

## 7. Video

Layers and their priority, tile formats and bit-plane order, palette format,
scroll registers and their sign, sprite format and draw order, clipping,
flip-screen, anything that accumulates between frames. Draw order is a
specification: write it as numbered steps.

## 8. ROMs

| file | CRC32 | size | region | how it is interleaved |
|---|---|---|---|---|

## 9. What the program actually uses

From the ROM in Ghidra or MAME's debugger: which features of the chips above
this game touches, and which it never does. What is never touched need not be
built — but write down that it was left out, and why that is safe.

## 10. Open questions

What is still a guess. Delete entries as they are settled, with the evidence.
