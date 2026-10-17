#!/bin/sh
# Publish a release built from a specific, hardware-verified CI build.
#
# Usage: cut-release.sh <tag> <run-id | bitstream.rbf_r>
#        cut-release.sh v1.0.0 32214080417
#        cut-release.sh v1.0.0 release/pocket/Cores/<id>/bitstream.rbf_r
#
# Takes the bitstream from that CI run, or the local file that was flashed,
# rather than recompiling, so the release ships the exact gateware that was
# tested on hardware. Everything outside the
# bitstream (JSON definitions, platform image, ROM recipe, README) comes from
# the working tree, which is how a definition-only change can be released
# without a rebuild.
#
# Creating the tag triggers the Compile Core workflow; it sees the release
# already exists and skips publishing, leaving this artifact in place.
set -e
TAG="$1"
RUN="$2"
[ -n "$TAG" ] && [ -n "$RUN" ] || { echo "usage: cut-release.sh <tag> <run-id>"; exit 1; }
cd "$(dirname "$0")/.."

command -v gh >/dev/null || { echo "gh CLI required"; exit 1; }
if gh release view "$TAG" >/dev/null 2>&1; then
    echo "release $TAG already exists; delete it first or pick another tag"; exit 1
fi
if [ -n "$(git status --porcelain pkg target rtl platform projects)" ]; then
    echo "working tree has uncommitted core changes; commit them so the tag matches"; exit 1
fi
# Updaters and the openFPGA core library read version and date_release from
# the core.json in the zip, not from the tag: a release whose version was
# bumped but whose date was not was listed under the previous release's date
# (fifteen Analogizer releases, 2026-10).  Every core.json must name this tag
# and carry today's date.
TODAY=$(date +%Y-%m-%d)
for cj in pkg/pocket/Cores/*/core.json; do
    python3 - "$cj" "$TAG" "$TODAY" <<'EOF' || exit 1
import json, sys
p, tag, today = sys.argv[1:4]
m = json.load(open(p))['core']['metadata']
bad = []
if 'v' + m['version'] != tag and m['version'] != tag:
    bad.append(f"version {m['version']} is not the tag {tag}")
if m.get('date_release') != today:
    bad.append(f"date_release {m.get('date_release')} is not today, {today}")
if bad:
    sys.exit(f"{p}: " + "; ".join(bad) + " -- bump both and commit")
EOF
done

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

if [ -f "$RUN" ]; then
    # a local bitstream: the one that was put on the card and tested
    echo "bitstream from $RUN (md5 $(md5 -q "$RUN" 2>/dev/null || md5sum "$RUN" | cut -d' ' -f1))"
    cid=$(basename "$(ls -d pkg/pocket/Cores/*/ | head -1)")
    mkdir -p "$STAGE/local/$cid"
    cp "$RUN" "$STAGE/local/$cid/bitstream.rbf_r"
else
    echo "fetching bitstream from run $RUN ..."
    gh run download "$RUN" -D "$STAGE" || { echo "download failed"; exit 1; }
fi
# The run ships one bitstream per core, each under its own Cores/<id>/ folder.
CORES=$(find "$STAGE" -name 'bitstream.rbf_r' -exec dirname {} \; | xargs -n1 basename | sort -u)
[ -n "$CORES" ] || { echo "no bitstream in run $RUN"; exit 1; }
for c in $CORES; do
    RBF=$(find "$STAGE" -path "*/$c/bitstream.rbf_r" | head -1)
    SIZE=$(wc -c < "$RBF")
    [ "$SIZE" -gt 500000 ] || { echo "$c bitstream only $SIZE bytes, looks truncated"; exit 1; }
done

# Assemble the package: definitions from the tree, bitstream from the run.
OUT="$STAGE/release/pocket"
rm -rf "$OUT"; mkdir -p "$OUT"
# A ROM may sit in pkg/pocket/Assets locally (gitignored); never ship it.
tar -cf - --exclude '.DS_Store' --exclude '*.rom' --exclude '*.zip' \
    -C pkg/pocket . | tar -xf - -C "$OUT"
for c in $CORES; do
    RBF=$(find "$STAGE" -path "*/$c/bitstream.rbf_r" | head -1)
    [ -d "$OUT/Cores/$c" ] || { echo "run has a bitstream for $c but the tree has no such core"; exit 1; }
    cp "$RBF" "$OUT/Cores/$c/bitstream.rbf_r"
done
# A core folder with no bitstream would be one the Pocket cannot load.
for d in "$OUT"/Cores/*/; do
    [ -f "$d/bitstream.rbf_r" ] || { echo "no bitstream for $(basename "$d") in run $RUN"; exit 1; }
done
for extra in mycore.mra README.md tools/mra_build.py; do
    [ -f "$extra" ] && cp "$extra" "$OUT/$(basename "$extra")"
done

# Sanity-check the package before it goes out.
for c in $CORES; do
    for f in core.json input.json interact.json data.json; do
        [ -e "$OUT/Cores/$c/$f" ] || { echo "package missing Cores/$c/$f"; exit 1; }
    done
    plat=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['core']['metadata']['platform_ids'][0])" \
           "$OUT/Cores/$c/core.json")
    [ -e "$OUT/Platforms/$plat.json" ] || { echo "package missing Platforms/$plat.json"; exit 1; }
    # the platform image is the user's to supply (CLAUDE.md); the core works without it
    [ -e "$OUT/Platforms/_images/$plat.bin" ] || echo "note: no Platforms/_images/$plat.bin (none supplied yet)"
done
for j in "$OUT"/Cores/*/*.json "$OUT"/Platforms/*.json; do
    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$j" || { echo "bad json: $j"; exit 1; }
done
if find "$OUT" -name '*.rom' | grep -q .; then
    echo "refusing to publish: a ROM is in the package"; exit 1
fi

VER=$(python3 -c "import json;print(json.load(open('pkg/pocket/Cores/plasticbugs.mycore/core.json'))['core']['metadata']['version'])")
# names from the package, so a core made from the template never ships
# another core's (this line once named MCR-68000 in NBA Jam's release)
SHORT=$(python3 -c "import json,glob;print(json.load(open(sorted(glob.glob('pkg/pocket/Cores/*/core.json'))[0]))['core']['metadata']['shortname'])")
TITLE=$(python3 -c "import json,glob;print(json.load(open(sorted(glob.glob('pkg/pocket/Platforms/*.json'))[0]))['platform']['name'])")
ZIP="$PWD/$SHORT-pocket-sdcard.zip"
rm -f "$ZIP"
(cd "$OUT" && zip -qr "$ZIP" .)
echo "package $VER, zip $(wc -c < "$ZIP") bytes"
for c in $CORES; do
    echo "  $c  md5 $(md5 -q "$OUT/Cores/$c/bitstream.rbf_r")"
done

gh release create "$TAG" \
    --title "$TITLE for Analogue Pocket $TAG" \
    --notes-file docs/release-notes.md \
    "$ZIP"
rm -f "$ZIP"
echo "published $TAG"
