#!/bin/sh
# SessionStart hook — warn when THIS project has an unresolved handoff to a
# Tireless workspace, so a local session checks the workspace for newer work
# before editing. Local file reads only: no network, no git mutations, exits
# silently in the overwhelmingly common no-record case. Anything unexpected
# must never block a session from starting — hence the global exit-0 posture.
set -u

REC_DIR="$HOME/.timeless/handoffs/out"
[ -d "$REC_DIR" ] || exit 0

# Records are keyed by the repo toplevel (fall back to cwd outside a repo —
# matches what handoff-sync recorded for tar-mode directories).
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
ROOT_ID="$(printf '%s' "$ROOT" | cksum | awk '{print $1}')"

for rec in "$REC_DIR"/*"--$ROOT_ID.rec"; do
  [ -f "$rec" ] || continue
  get() { sed -n "s/^$1=//p" "$rec" | head -1; }
  [ "$(get RESOLVED)" = yes ] && continue
  ws="$(get WS)"
  branch="$(get BRANCH)"
  synced="$(get SYNCED_AT)"
  printf '[tireless] Pending workspace handoff: this project was handed off to workspace "%s" (branch %s) at %s and has not been pulled back since. The workspace copy may be ahead of this one. Before local edits, run `tireless-handoff-check` (read-only) to see if the workspace has newer work; bring it back with `tireless-handoff-pull` (continue skill has the full flow), or clear a stale record with `tireless-handoff-pull --forget`.\n' \
    "$ws" "${branch:-?}" "${synced:-?}"
done
exit 0
