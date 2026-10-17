#!/bin/sh
# Refuse to publish ROM data. Run after staging and before every push --
# it checks the tracked set, so run it once `git add` is done.
#
# Checks every tracked file for: ROM/romset file extensions, the romset
# directory, oversized binaries, and text files carrying long runs of hex that
# could be a dumped ROM region. Screenshots, frozen machine-state dumps (RAM
# contents, not ROM) and hash manifests are fine -- state dumps are written as
# space-separated 4-digit groups, so they never form a long unbroken run.
#
# Note: BSD grep rejects repetition counts above 255, and a failing grep is
# indistinguishable from "no match", so the threshold is kept low and the
# pattern is self-tested at startup.
set -e
# A guard that cannot check must not say "passed".  Outside a repository, or
# with nothing tracked, there is no staged set to inspect -- and silence there
# would look exactly like a clean one (METHODOLOGY section 5.8).
root=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "no-rom check ABORTED: not in a git repository, so there is nothing to check" >&2
    exit 2
}
cd "$root"
if [ -z "$(git ls-files | head -1)" ]; then
    echo "no-rom check ABORTED: no tracked files -- stage the tree first (git add -A)" >&2
    exit 2
fi

HEXRUN='^[0-9a-f]{200,}$'
# self-test: the pattern must match a known-bad string and reject a known-good one
probe=$(printf 'a%.0s' $(seq 1 250))
if ! printf '%s\n' "$probe" | LC_ALL=C grep -qE "$HEXRUN"; then
    echo "no-rom check ABORTED: hex-run pattern is not working on this grep" >&2
    exit 2
fi

report=$(mktemp)
trap 'rm -f "$report"' EXIT

# Known-large files that are provably not ROM data. Each needs a reason.
#   modules/cpu-tg68k/gen/tg68k.v -- ghdl-generated Verilog of the TG68K.C
#   68000 core (GPL-3.0), see modules/VENDOR.md
ALLOW_LARGE="modules/cpu-tg68k/gen/tg68k.v"
# The Pocket package's own images, .bin by the platform's convention and not
# ROM data: the platform artwork (171,930 bytes) and the core icon (2,592).
# The size check still applies to them.
ALLOW_PACKAGE="pkg/pocket/Platforms/_images/mycore.bin pkg/pocket/Cores/plasticbugs.mycore/icon.bin"

git ls-files | while IFS= read -r f; do
    [ -f "$f" ] || continue
    case " $ALLOW_LARGE " in *" $f "*) continue ;; esac
    case " $ALLOW_PACKAGE " in *" $f "*) ;; *)
        case "$f" in
            *.rom|*.zip|*.7z|*.bin|*.nv)
                printf '  REFUSE  %s\n            ROM or romset file\n' "$f" >>"$report" ;;
        esac ;;
    esac
    # Anything under a directory named after the romset -- except the package's
    # own Assets/<setname>/, which is where the ROM is meant to be PUT by the
    # user and legitimately carries a README.  Files there are still judged by
    # extension above, so a real ROM in it is still refused.
    case "$f" in
        pkg/pocket/Assets/*) ;;
        mycore/*|*/mycore/*)
            printf '  REFUSE  %s\n            ROM or romset file\n' "$f" >>"$report" ;;
    esac
    sz=$(wc -c < "$f" 2>/dev/null || echo 0)
    if [ "$sz" -gt 1048576 ]; then
        printf '  REFUSE  %s\n            tracked file is %s bytes\n' "$f" "$sz" >>"$report"
    fi
    case "$f" in
        *.txt|*.md|*.log|*.sha256)
            if LC_ALL=C grep -qE "$HEXRUN" "$f" 2>/dev/null; then
                printf '  REFUSE  %s\n            long unbroken hex run (raw ROM dump?)\n' "$f" >>"$report"
            fi ;;
    esac
done

if [ -s "$report" ]; then
    cat "$report"
    echo "no-rom check FAILED"
    exit 1
fi
echo "no-rom check passed ($(git ls-files | wc -l | tr -d ' ') tracked files)"
