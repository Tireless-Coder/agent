#!/bin/sh
# session-warm.sh — SessionStart: re-mint the per-cell Coder session BEFORE
# the agent needs it, so an 8h expiry never surfaces as a mid-task failure.
#
# Why this exists. Healing on failure is not enough: the failure that healing
# repairs is the agent's OWN `ssh <workspace>.tireless '…'` call, which goes
# through the user's Bash tool and touches none of our code. The agent sees a
# raw Coder error, forms its own theory (2026-07-27: it read `signed_in: true`
# from tireless_status, decided the platform token was the problem, and
# refreshed the wrong auth layer twice before finding the real one), and the
# user watches it flounder. The cheapest way to not have that conversation is
# for the session to be alive when the agent starts working.
#
# Cost control — this must never delay a session start:
#   - the staleness test is a file mtime, so the common "nothing to do" case
#     is a stat and no network at all
#   - when a re-mint IS due it runs fully detached; this script exits at once
#   - one line of context is printed so the agent knows a heal is in flight
#     (SessionStart stdout becomes context) and knows the routine name for it
#   - a lock dir keeps concurrent windows from minting on top of each other
#   - TIRELESS_NO_AUTOHEAL=1 turns the whole thing off
#
# Nothing here may fail a session start: exit 0 on every path.
set -u

[ "${TIRELESS_NO_AUTOHEAL:-0}" = 1 ] && exit 0

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
. "$SCRIPT_DIR/alias.sh"

# Re-mint at 7h (tireless_warm_due, alias.sh). Cells cap sessions at 7h59m
# with no sliding refresh, so this lands inside the window where the current
# session is still GOOD — the heal is invisible, and a laptop that slept
# through the boundary is covered by the same pass.
STATE_DIR="$HOME/.timeless"
LOCK="$STATE_DIR/warm.lock"
LOG="$STATE_DIR/warm.log"

tireless_warm_due || exit 0
# No record written means no cooldown, and no cooldown means every session
# start warms. Refuse rather than loop.
tireless_warm_mark || exit 0

# mkdir is the atomic test-and-set. A lock left behind by a killed heal must
# not disable warming forever, so anything older than 10 minutes is reaped.
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
if [ -d "$LOCK" ] && [ -n "$(find "$LOCK" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
  rmdir "$LOCK" 2>/dev/null || true
fi
mkdir "$LOCK" 2>/dev/null || exit 0

# Detached: double-fork + nohup so the heal survives this hook's exit (and its
# timeout) instead of being taken down with the process group. The log is
# truncated per run (`>`), so it stays a "what happened last time" file rather
# than an unbounded one; the lock is released by the same shell that took it,
# whatever the heal's exit status.
( nohup sh -c 'sh "$1" >"$2" 2>&1; rmdir "$3" 2>/dev/null || true' \
    sh "$SCRIPT_DIR/session-heal.sh" "$LOG" "$LOCK" >/dev/null 2>&1 & ) &

printf '[tireless] Your cloud workspace session was minted over %s hours ago; cells cap them at 8h, so a headless re-mint (no browser, no paste, no user action) is running in the background right now. If a `tireless` command or `ssh <workspace>.tireless` fails on auth in the next few seconds, that is this — run `tireless-session-heal`, read its first line, and retry the command. It is routine expiry, never a broken setup, and it is NOT the platform sign-in: `tireless_status` reporting signed_in true says nothing about this layer.\n' \
  "$((TIRELESS_WARM_STALE_MINUTES / 60))"
exit 0
