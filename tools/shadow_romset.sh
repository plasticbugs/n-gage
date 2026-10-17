#!/bin/sh
# Build a shadow romset in .mame/roms: symlinks to the user's real ROMs, plus
# placeholders for files MAME insists on but no emulation reads (PAL and PLD
# dumps, usually) and which a romset often does not carry.  The user's own
# files are never touched or polluted.
#
#   tools/shadow_romset.sh [romset-dir]
#
# EDIT: name the files MAME demands and nothing reads, with their sizes.
PLACEHOLDERS=""          # e.g. "pal16l8.ic3:260 pal20l8.ic23:260"
set -e
root=$(cd "$(dirname "$0")/.." && pwd)
src=${1:-$root/mycore}
dst=$root/.mame/roms/mycore
[ -d "$src" ] || { echo "no romset directory at $src" >&2; exit 2; }
mkdir -p "$dst" "$root/.mame/cfg" "$root/.mame/nvram"
for f in "$src"/*; do ln -sf "$f" "$dst/$(basename "$f")"; done
for spec in $PLACEHOLDERS; do
    p=${spec%%:*}; n=${spec##*:}
    [ -e "$src/$p" ] || python3 -c "open('$dst/$p','wb').write(b'\xff'*$n)"
done
echo "shadow romset ready: $dst"
