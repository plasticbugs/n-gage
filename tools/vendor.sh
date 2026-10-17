#!/bin/sh
# Fetch a vendored CPU or sound core from its upstream into modules/, at a
# pinned commit, with its licence.
#
#   tools/vendor.sh <name>              a known module, from the table below
#   tools/vendor.sh <name> <url> <ref> [subdir]   anything else
#
# Vendored rather than submoduled so the build is self-contained and
# reproducible: a clone of this repository compiles without fetching anything.
# After fetching, record it in modules/VENDOR.md and run tools/gen_qip.sh.
#
# A block proven in another core is proven on that core's signal, not yours:
# measure it on this core's for whatever its original host never presented --
# DC, full-scale peaks, sample rate, duty (METHODOLOGY section 5.14).
set -e
cd "$(dirname "$0")/.."

# name|repository|ref|subdirectory (empty = whole repo)|what it is
KNOWN='
cpu-fx68k|https://github.com/ijor/fx68k|master||68000, cycle-accurate (GPL-3.0, Jorge Cwik)
cpu-t80|https://github.com/MiSTer-devel/T80|master||Z80 (GPL-2.0-ish; see its header)
cpu-tv80|https://github.com/hoglet67/tv80|master|rtl/core|Z80 (MIT, Guy Hutchison)
sound-jt12|https://github.com/jotego/jt12|master|hdl|YM2612/YM2203 family (GPL-3.0, Jose Tejada)
sound-jt49|https://github.com/jotego/jt49|master|hdl|AY-3-8910 / YM2149 (GPL-3.0, Jose Tejada)
sound-jt51|https://github.com/jotego/jt51|master|hdl|YM2151 (GPL-3.0, Jose Tejada)
sound-jt89|https://github.com/jotego/jt89|master|hdl|SN76489 (GPL-3.0, Jose Tejada)
'

name="$1"
[ -n "$name" ] || {
    echo "usage: $0 <name> [url ref [subdir]]"
    echo
    echo "known modules:"
    echo "$KNOWN" | while IFS='|' read -r n u r s d; do
        [ -n "$n" ] && printf '  %-14s %s\n' "$n" "$d"
    done
    exit 2
}

url="$2"; ref="$3"; sub="$4"
if [ -z "$url" ]; then
    line=$(echo "$KNOWN" | grep "^$name|" || true)
    [ -n "$line" ] || { echo "unknown module '$name'; give a url and ref, or see $0 with no arguments" >&2; exit 2; }
    url=$(echo "$line" | cut -d'|' -f2)
    ref=$(echo "$line" | cut -d'|' -f3)
    sub=$(echo "$line" | cut -d'|' -f4)
fi
[ -e "modules/$name" ] && { echo "modules/$name already exists; delete it first" >&2; exit 2; }

command -v git >/dev/null || { echo "git required" >&2; exit 2; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
echo "fetching $url @ $ref ..."
git clone -q --depth 1 --branch "$ref" "$url" "$tmp/src" 2>/dev/null \
  || git clone -q "$url" "$tmp/src"
commit=$(git -C "$tmp/src" rev-parse HEAD)

mkdir -p "modules/$name"
src="$tmp/src${sub:+/$sub}"
[ -d "$src" ] || { echo "no '$sub' in that repository" >&2; exit 2; }
find "$src" -maxdepth 1 -type f \( -name '*.v' -o -name '*.sv' -o -name '*.vh' -o -name '*.svh' -o -name '*.mem' -o -name '*.hex' \) \
    -exec cp {} "modules/$name/" \;
for l in LICENSE LICENSE.txt LICENSE.md COPYING COPYING.txt; do
    [ -f "$tmp/src/$l" ] && cp "$tmp/src/$l" "modules/$name/" && break
done
[ -f "modules/$name/LICENSE" ] || [ -f "modules/$name/COPYING" ] || \
    echo "  !! no licence file found upstream -- find it and add one by hand"

n=$(ls "modules/$name" | wc -l | tr -d ' ')
echo "modules/$name: $n files at $commit"
echo
echo "Now: add a row to modules/VENDOR.md --"
echo "| $name | $url | $commit | *(licence)* |"
echo "then run tools/gen_qip.sh, and delete anything the core does not instantiate."
