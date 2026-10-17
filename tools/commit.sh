#!/bin/sh
# The only way commits are made here: stage everything, run the ROM guard on
# the staged tree, commit with the message file, push. The guard's failure is
# fatal -- it is never piped, so its exit status cannot be lost.
#   tools/commit.sh <message-file> [--no-push] [-- path...]
# With paths, only those are staged (one logical change per commit).
set -e
cd "$(git rev-parse --show-toplevel)"
[ -f "$1" ] || { echo "usage: $0 <message-file> [--no-push] [-- path...]" >&2; exit 2; }
MSG="$1"; shift
PUSH=1
[ "$1" = "--no-push" ] && { PUSH=0; shift; }
if [ "$1" = "--" ]; then shift; git add -A -- "$@"; else git add -A; fi
tools/check-no-roms.sh
git -c user.email=scottmosch@gmail.com -c user.name="Scott Moschella" commit -q -F "$MSG"
[ "$PUSH" = 0 ] || git push -q origin main
git log --oneline -1
