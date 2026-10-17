#!/bin/sh
# Lint every module in rtl/ on its own, so a warning has one obvious owner.
# Run before every push: it costs seconds and catches what a two-minute
# Quartus map would, without waiting for Quartus.
#
# The vendored cores are waived by rule and path. The waiver file is built
# here rather than committed, because Verilator rejects the whole file if it
# names a rule that version does not know -- which is how a waiver written
# against the newest Verilator broke the lint on CI's older one. Each rule is
# probed first and only the ones that exist go in.
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
verilator --version >/dev/null 2>&1 || { echo "verilator not found" >&2; exit 2; }

. "$here/waivers.sh"
WAIVE="$WAIVERS"

PROBE=$(mktemp -d)
trap 'rm -rf "$PROBE"' EXIT
echo 'module lintprobe; endmodule' > "$PROBE/lintprobe.v"

OPTS="-Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-TIMESCALEMOD"
for w in UNUSEDPARAM PINCONNECTEMPTY; do
    verilator --lint-only "-Wno-$w" "$PROBE/lintprobe.v" >/dev/null 2>&1 \
        && OPTS="$OPTS -Wno-$w"
done

# vendored modules, if there are any yet
MODS=$(ls "$root"/modules/*/*.v "$root"/modules/*/*.sv 2>/dev/null || true)

fail=0
for f in "$root"/rtl/*.sv; do
    m=$(basename "$f" .sv)
    printf '%-20s ' "$m"
    out=$(verilator --lint-only $OPTS "$WAIVE" --top-module "$m" \
          "$root"/rtl/*.sv $MODS 2>&1 \
          | grep -E '^%(Error|Warning)' | grep -v 'Exiting due to' || true)
    if [ -z "$out" ]; then echo ok
    else echo; echo "$out" | sed 's/^/    /'; fail=1
    fi
done

printf '%-20s ' "pocket memories"
out=$(verilator --lint-only $OPTS "$WAIVE" --top-module mycore_mem \
      "$root"/target/pocket/mycore_mem.sv "$root"/target/pocket/sdram_ctrl.sv \
      "$root"/target/pocket/sram_port.sv 2>&1 \
      | grep -E '^%(Error|Warning)' | grep -v 'Exiting due to' \
      | grep -v 'sdram_ctrl.sv' || true)
if [ -z "$out" ]; then echo ok
else echo; echo "$out" | sed 's/^/    /'; fail=1
fi

printf '%-20s ' "sram self-test"
out=$(verilator --lint-only $OPTS "$WAIVE" --top-module sram_selftest \
      "$root"/target/pocket/sram_selftest.sv 2>&1 \
      | grep -E '^%(Error|Warning)' | grep -v 'Exiting due to' || true)
if [ -z "$out" ]; then echo ok
else echo; echo "$out" | sed 's/^/    /'; fail=1
fi

# the Analogizer wrapper, with the adapter's vendored module behind it and a
# stand-in for its one VHDL file.  The vendored files are kept as upstream wrote
# them, so their warnings are dropped by path (as sdram_ctrl's are above; the
# waiver file's -file patterns do not take on them) -- their errors are not,
# but for one: hq2x.sv (MiSTer's) assigns its output wire in an always block,
# which Quartus takes and Verilator calls an error.
# yc_out_legacy.sv goes through sim/yc_out_legacy_stub.v (its sine table, a
# wire array with an initial value, is past CI's Verilator 5.020), and
# BLKANDNBLK in the vendored SNAC module is waived (5.020 cannot lint it).
# Twice: as built, and with the options a core may set (SAME_CLK, and the
# adapter module's USE_YC / USE_SD, its one local change).
A="$root"/target/pocket/analogizer
for v in "" "-GSAME_CLK=1'b1 -GUSE_YC=0 -GUSE_SD=0"; do
    printf '%-20s ' "analogizer${v:+ options}"
    out=$(verilator --lint-only $OPTS -Wno-PROCASSWIRE -Wno-BLKANDNBLK "$WAIVE" --top-module pocket_analogizer $v \
          "$root"/target/pocket/pocket_analogizer.sv "$root"/platform/pocket/helpers/synch_3.sv \
          "$A"/*.v $(ls "$A"/*.sv | grep -v /yc_out_legacy.sv) "$here"/yc_out_legacy_stub.v "$here"/ps2_keyboard_stub.v 2>&1 \
          | grep -E '^%(Error|Warning)' | grep -v 'Exiting due to' \
          | grep -v -E '^%Warning[^ ]*: [^ ]*/(target/pocket/analogizer|platform/pocket)/' || true)
    if [ -z "$out" ]; then echo ok
    else echo; echo "$out" | sed 's/^/    /'; fail=1
    fi
done

# the 15 kHz converter for a board that is not 15 kHz (docs/analogizer.md)
printf '%-20s ' "ana_15k"
out=$(verilator --lint-only $OPTS "$WAIVE" --top-module ana_15k \
      "$root"/target/pocket/ana_15k.sv 2>&1 \
      | grep -E '^%(Error|Warning)' | grep -v 'Exiting due to' || true)
if [ -z "$out" ]; then echo ok
else echo; echo "$out" | sed 's/^/    /'; fail=1
fi

[ $fail = 0 ] || exit 1
echo "lint clean"
