#!/bin/sh
# SessionStart hook — thin shim onto scripts/session-warm.sh, which keeps the
# per-cell Coder session alive so an 8h expiry never lands in the middle of a
# task. The real logic (and the reasoning) lives in the script; hooks stay
# one-liners so the same behavior is reachable from Codex/Cursor installs,
# which have the scripts but not this hook.
set -u
exec sh "$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)/scripts/session-warm.sh"
