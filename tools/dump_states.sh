#!/bin/sh
# Dump video states from MAME, checking that the run actually reached every
# frame asked for.  MAME sometimes ends a headless run early without saying
# so, which would otherwise show up much later as a missing state file.
#
#   tools/dump_states.sh <dir> <frames,...> [lite_from-lite_to] [extra mame args]
#
# The optional third argument asks for a small per-frame dump (control
# registers and sprite RAM) across a range, which is what the framebuffer
# replay needs to follow a never-cleared framebuffer.
set -e
root=$(cd "$(dirname "$0")/.." && pwd)
dir=$1; frames=$2; shift 2
lite=
case "$1" in [0-9]*-[0-9]*) lite=$1; shift;; esac
mkdir -p "$dir"
last=$(printf '%s\n%s' "$frames" "$lite" | tr ',-' '\n\n' | sort -n | tail -1)
secs=$(( last / 60 + 3 ))
for try in 1 2 3 4 5; do
    rm -f "$dir"/run.txt
    LITE="$lite" DUMPFRAMES="$frames" DUMP_DIR="$dir" "$root/tools/mame.sh" \
        -seconds_to_run "$secs" -autoboot_script "$root/tools/dump_state.lua" \
        "$@" >/dev/null 2>&1 || true
    if [ -f "$dir/run.txt" ] && ! grep -q MISSING "$dir/run.txt"; then
        echo "$(grep '^frames' "$dir/run.txt"), all states present (attempt $try)"
        exit 0
    fi
    echo "attempt $try incomplete, retrying" >&2
done
echo "error: MAME would not complete the run" >&2
exit 1
