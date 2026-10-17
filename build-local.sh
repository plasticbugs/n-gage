#!/bin/sh
# Compile the My Core Pocket core with Quartus 18.1 in Docker (x86 emulation on ARM Macs).
#
#   ./build-local.sh          full compile + package
#   ./build-local.sh map      analysis & synthesis only (~a couple of minutes)
#
# Run the map check before every push: it catches syntax and inference errors
# without paying for a full fit, and a broken push costs a whole CI cycle.
set -e
cd "$(dirname "$0")"
FLOW=${1:-compile}
case "$FLOW" in
    map) CMD="quartus_map --read_settings_files=on projects/mycore_pocket.qpf -c mycore_pocket" ;;
    compile) CMD="quartus_sh --flow compile projects/mycore_pocket.qpf" ;;
    *) echo "usage: $0 [map|compile]"; exit 2 ;;
esac
docker run --rm --platform linux/amd64 \
    -v "$PWD":/build -w /build \
    raetro/quartus:pocket \
    $CMD
[ "$FLOW" = compile ] && python3 package-pocket.py || true
