#!/bin/sh
# session-heal.sh — re-mint an EXPIRED per-cell Coder session, headlessly.
#
# Cells cap Coder sessions at 8 hours with no sliding refresh, so a dead
# session is the normal state of an overnight laptop, not an incident. The
# platform can mint a replacement server-side (SPEC-AGENT-CONNECTOR §11.4):
# no browser, no tty, no token in the chat. This script is the ONE command an
# agent runs when `tireless list`, `tireless ping` or an ssh attempt fails on
# auth — instead of reporting the raw failure and asking the user to log in.
#
# An AGENT must never invoke `tireless-connect login` itself: that command
# falls through to a loopback BROWSER flow when the platform token is also
# dead, which inside an agent's Bash tool means a hung call and a stalled
# session. This script may — and on the connector builds that are actually in
# the field, must — because it wraps that call in the three guards the bare
# command lacks (--no-browser, no tty, a watchdog). See heal_via_login.
#
# Output is KEY=val; the FIRST line is SESSION=.
#
#   SESSION=ok               every region already had a live session
#   SESSION=healed           at least one region was re-minted (re-run what failed)
#   SESSION=action_required  only the user can fix this — CODE/NEXT say how
#   SESSION=fail             unexpected breakage — DETAIL says what
#   VIA=ensure-session|login|none    which connector path did the work
#   CODE=E_*                 fix code, matching the fix skill's map
#   DETAIL=<one line>        never contains a token
#   NEXT=<what to do next>
#
# Mutating (it writes the connector's own 0600 session files), so it stays
# prompt-gated when an AGENT reaches for it — it is never added to a skill's
# pre-approved allowed-tools. The two warming hooks (hooks/session-warm.sh,
# hooks/pre-tool-warm.sh) do run it unattended, which is a deliberate and
# disclosed exception: hooks sit outside the permission system, the act is a
# re-mint of the user's own short-lived session, and the alternative is
# letting a routine daily expiry break the user's command. README's security
# notes state it, and TIRELESS_NO_AUTOHEAL=1 turns it off.
set -eu

. "$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/alias.sh"

# `if` rather than `[ … ] && echo`: under `set -e` a false test at the head of
# an && list takes the whole script's exit status with it.
emit() {
  echo "SESSION=$1"
  echo "VIA=$2"
  if [ -n "${3:-}" ]; then echo "CODE=$3"; fi
  if [ -n "${4:-}" ]; then echo "DETAIL=$4"; fi
  if [ -n "${5:-}" ]; then echo "NEXT=$5"; fi
}

# One line, no newlines, no stray CR — the KEY=val contract survives whatever
# the connector printed.
oneline() {
  printf '%s' "$1" | tr '\r\n' '  ' | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//' | cut -c1-400
}

# A live session is a session that ANSWERS, not one we were told about: after
# any heal we re-probe the regional dirs ourselves. This is why the script
# never has to trust the connector's prose — a future wording change cannot
# turn a failed heal into a reported success.
#
# "Live" means AT LEAST ONE regional session answers, not all of them.
# Requiring all was wrong: a machine that has both the platform installer's
# state root and the connector's (or a leftover dir for a region the account
# no longer has) carries dirs that ensure-session will never mint into,
# because it only mints regions the platform currently lists. Demanding those
# answer turns every successful heal on such a machine into SESSION=fail, and
# the caller then never retries the thing that actually would have worked.
sessions_live() {
  tireless_cli_bin >/dev/null || return 1
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    if [ "$(tireless_session_probe "$d")" = ok ]; then return 0; fi
  done <<EOF
$(tireless_coder_dirs)
EOF
  return 1
}

# tireless-connect lives on PATH, in the Claude plugin data dir (the plugin
# launcher installs it there), or in ~/.local/bin.
CONNECT=""
for c in \
  "$(command -v tireless-connect 2>/dev/null || true)" \
  "${CLAUDE_PLUGIN_DATA:-$HOME/.claude/plugins/data/tireless}/bin/tireless-connect" \
  "$HOME/.local/bin/tireless-connect"
do
  if [ -n "$c" ] && [ -x "$c" ]; then CONNECT="$c"; break; fi
done

if [ -z "$CONNECT" ]; then
  emit action_required none E_BIN_STALE \
    "tireless-connect is not installed on this machine" \
    "install it: curl -fsSL https://app.tirelesscode.com/connect/install.sh | sh (Claude Code: restart the session, the plugin launcher installs it)"
  exit 1
fi

# ── one heal at a time, machine-wide ────────────────────────────────────────
#
# A mint is a ROTATION: the platform reaps the previous `tireless-connect`
# token before issuing the new one. Two heals racing therefore do not merely
# duplicate work, they can destroy the result — A mints, B reaps A's token and
# mints, A writes its now-dead token last, and the session on disk is broken by
# the very thing that was repairing it.
#
# That race is not hypothetical here: a laptop resumed after a night runs the
# SessionStart warm (detached, ~3 s) and, if the agent's first ssh lands inside
# that window, the PostToolUseFailure heal — concurrently, from two different
# hooks with two different guard files. Connector 0.4.2 has no mint lock of its
# own, so this is the only place the exclusion can live.
#
# A waiter does NOT mint. It waits for the holder, then re-probes: if the peer
# succeeded, that is a healed session and saying so is both true and free.
HEAL_LOCK="$HOME/.timeless/heal.lock"
mkdir -p "$HOME/.timeless" 2>/dev/null || true
HELD_LOCK=no
waited=0
while [ "$waited" -lt 40 ]; do
  if mkdir "$HEAL_LOCK" 2>/dev/null; then HELD_LOCK=yes; break; fi
  # A lock left behind by a killed heal must never wedge repairs shut.
  if [ -n "$(find "$HEAL_LOCK" -maxdepth 0 -mmin +2 2>/dev/null)" ]; then
    rmdir "$HEAL_LOCK" 2>/dev/null || true
    continue
  fi
  sleep 1
  waited=$((waited + 1))
done
if [ "$HELD_LOCK" = yes ]; then
  trap 'rmdir "$HEAL_LOCK" 2>/dev/null || true' EXIT INT TERM
else
  # The peer never released it. Trust the probe over the clock: a live session
  # means the peer did the job, and minting on top of it would undo that.
  if sessions_live; then
    emit healed peer "" \
      "the session is live; another heal on this machine holds the lock, so this run minted nothing" \
      "re-run whatever failed — the session is live"
    exit 0
  fi
  emit fail peer E_CODER_LOGIN \
    "another heal has held the machine-wide lock for over 40s and the session is still not live" \
    "wait for it to finish, then run the fix skill's doctor step"
  exit 1
fi

# The peer may have finished while we waited for the lock. Re-probe before
# spending a mint: a heal that was already done is `ok`, not more work.
if [ "$waited" -gt 0 ] && sessions_live; then
  emit healed peer "" \
    "the session is live after waiting for another heal on this machine; this run minted nothing" \
    "re-run whatever failed — the session is live"
  exit 0
fi

# Path 2 — every connector build in the field (<= 0.4.2) predates
# `ensure-session`. On those, `login` is the ONLY headless heal there is: its
# phase 2 runs the exact same server-side mint (RunLogin prints "cell <id>:
# Coder session established (server-minted, no paste)"), and its phase 1 is a
# NO-OP whenever the platform token is live or merely refreshable — which is
# the case in the overwhelming majority of expiries, because the platform
# token refreshes itself and the Coder session cannot.
#
# `doctor` used to be this fallback. It was never able to do the job: on
# 0.4.2 CoderListOK only REPORTS the dead session (doctor.go: "Coder session
# missing for region %s") and re-minting during diagnosis did not land until
# the unshipped 0.4.3. So the fallback was advising users to "update the
# connector" — to a build that does not exist yet — on the one path that had
# a working repair sitting right next to it.
#
# The hazard `login` carries is phase 1 falling through to the browser PKCE
# flow when the platform token is dead too: flow.Wait then blocks until the
# loopback callback fires, and an agent's Bash call hangs. Three guards, none
# of which trust the connector to behave:
#   --no-browser  nothing is ever opened — the authorize URL is printed
#   </dev/null    no tty, so nothing can block waiting for a paste
#   watchdog      the run is bounded, and the instant login prints its
#                 "open this URL" line we stop and hand that URL to the user
#                 rather than waiting out the clock
# The marker and the URL arrive in ONE unbuffered write (RunLogin formats them
# in a single Fprintf), so seeing the marker means the URL is already there.
LOGIN_TIMEOUT="${TIRELESS_HEAL_TIMEOUT:-90}"
# Everything this function starts must die with it. When a hook exceeds its
# own timeout the harness aborts the script mid-wait, and without this the
# backgrounded `tireless-connect login` SURVIVES: it goes on to mint and
# rewrite ssh fragments minutes later with nothing watching, while holding one
# of only three loopback OAuth ports (127.0.0.1:52180-52182) for up to five
# minutes — enough orphans and a real interactive login fails for want of a
# port. Observed live on 2026-07-27.
# Kill the process GROUP. `kill $pid` reaps only the tracked child; its own
# children survive with PPID 1 — in production that grandchild is
# `tireless config-ssh`, which goes on to rewrite ~/.ssh/config minutes after
# this script has already reported failure. `set -m` around the launch puts the
# child in its own group so the negative-pid kill can reach all of it.
cleanup_login() {
  if [ -n "${lpid:-}" ] && kill -0 "$lpid" 2>/dev/null; then
    kill -TERM -- "-$lpid" 2>/dev/null || kill -TERM "$lpid" 2>/dev/null || true
  fi
  if [ -n "${lout:-}" ]; then rm -f "$lout"; fi
}
LOGIN_MARKER='open this URL to sign in'

heal_via_login() {
  lout="$(mktemp "${TMPDIR:-/tmp}/tireless-login.XXXXXX")"
  trap 'cleanup_login; rmdir "$HEAL_LOCK" 2>/dev/null || true' EXIT INT TERM
  set -m 2>/dev/null || true
  "$CONNECT" login --no-browser </dev/null >"$lout" 2>&1 &
  lpid=$!
  set +m 2>/dev/null || true
  waited=0
  needs_human=no
  while [ "$waited" -lt "$LOGIN_TIMEOUT" ]; do
    kill -0 "$lpid" 2>/dev/null || break
    if grep -qs "$LOGIN_MARKER" "$lout"; then needs_human=yes; break; fi
    sleep 1
    waited=$((waited + 1))
  done
  timedout=no
  if kill -0 "$lpid" 2>/dev/null; then
    kill -TERM -- "-$lpid" 2>/dev/null || kill -TERM "$lpid" 2>/dev/null || true
    if [ "$needs_human" = no ]; then timedout=yes; fi
  fi
  wait "$lpid" 2>/dev/null || true
  lall="$(cat "$lout" 2>/dev/null || true)"
  rm -f "$lout"

  # The platform session is dead as well — the one case no headless path can
  # repair. Hand over the URL login already printed instead of a bare "sign
  # in again": it is an authorize URL (PKCE state, no secret), the same one
  # the MCP login tool returns.
  if [ "$needs_human" = yes ]; then
    url="$(printf '%s\n' "$lall" | grep -o 'https://[^ ]*' | head -1)"
    emit action_required login E_TOKEN_EXPIRED \
      "the PLATFORM session is dead too, so this re-mint needs a real sign-in" \
      "the USER opens ${url:-the URL printed by \`tireless-connect login\`} in their browser, or runs \`tireless-connect login\` in their OWN terminal, then replies done"
    exit 1
  fi
  # A per-region mint failure must not be averaged away by a region that was
  # already fine. `login` logs the failure and CONTINUES (it has no tty to fall
  # back to), still exiting 0 — and sessions_live only asks whether ANY dir
  # answers. Without this check, a two-cell user whose one needed cell failed
  # gets SESSION=healed and "re-run whatever failed", which fails identically.
  if printf '%s\n' "$lall" | grep -q 'could not mint a Coder session'; then
    failed="$(oneline "$(printf '%s\n' "$lall" | grep 'could not mint a Coder session' | head -2)")"
    emit fail login E_CODER_LOGIN \
      "at least one cell could not be re-minted: $failed" \
      "run tireless_doctor (or the fix skill) for that cell; do not blindly retry the failed command"
    exit 1
  fi
  # ok and healed are NOT interchangeable, and only login's own per-cell lines
  # can tell them apart: it prints "Coder session live" for a region it left
  # alone and "Coder session established (server-minted, no paste)" for one it
  # re-minted. Verifying with sessions_live alone would report `healed` for a
  # run that changed nothing (caught live, 2026-07-27) — which tells the caller
  # "re-run whatever failed" about a failure that was never an auth failure, so
  # it re-runs, fails identically, and is back where it started. `ok` sends it
  # to look elsewhere instead.
  if sessions_live; then
    if printf '%s\n' "$lall" | grep -q 'Coder session established'; then
      emit healed login "" \
        "re-minted through the connector's login path (server-minted, no browser, no paste)" \
        "re-run whatever failed — the session is live again"
    else
      emit ok login "" \
        "every region already had a live Coder session — nothing was re-minted" \
        "the Coder session layer is NOT what failed; diagnose the original error further (tireless_doctor / the fix skill)"
    fi
    exit 0
  fi
  case "$lall" in
    *"no region control planes resolved"*)
      emit ok login "" \
        "nothing to heal — this account has no workspace, so no cell session exists" \
        "create a workspace first (dashboard, or the tireless_create_workspace tool)"
      exit 0
      ;;
  esac
  if [ "$timedout" = yes ]; then
    emit fail login E_CODER_LOGIN \
      "\`tireless-connect login\` did not finish within ${LOGIN_TIMEOUT}s" \
      "re-run once; if it persists the USER runs \`tireless-connect login\` in their OWN terminal"
    exit 1
  fi
  emit fail login E_CODER_LOGIN \
    "$(oneline "${lall:-tireless-connect login produced no output}")" \
    "run the fix skill's doctor step; do not retry this blindly"
  exit 1
}

# Path 1 — the purpose-built headless entrypoint (connector >= 0.5.0).
out="$("$CONNECT" ensure-session 2>&1)" && rc=0 || rc=$?
case "$out" in
  *"unknown command"*) heal_via_login ;;
esac

state="$(printf '%s\n' "$out" | sed -n 's/^SESSION=//p' | head -1)"
code="$(printf '%s\n' "$out" | sed -n 's/^CODE=//p' | head -1)"
detail="$(oneline "$(printf '%s\n' "$out" | sed -n 's/^DETAIL=//p' | head -1)")"
next="$(oneline "$(printf '%s\n' "$out" | sed -n 's/^NEXT=//p' | head -1)")"
healed="$(printf '%s\n' "$out" | sed -n 's/^HEALED=//p' | head -1)"

case "$state" in
  ok|healed)
    # Trust, then verify: a mint that wrote files but produced a session the
    # CLI still rejects must not be reported as fixed.
    if sessions_live; then
      nextline=""
      if [ "$state" = healed ]; then
        if [ -n "$healed" ] && [ "$healed" != none ]; then
          detail="re-minted region(s): $healed"
        fi
        nextline="re-run whatever failed — the session is live again"
      fi
      emit "$state" ensure-session "" "${detail:-session verified live}" "$nextline"
      exit 0
    fi
    emit fail ensure-session E_CODER_LOGIN \
      "the connector reported $state but a \`tireless list\` probe still fails" \
      "run the fix skill's doctor step; do not retry this blindly"
    exit 1
    ;;
  action_required)
    emit action_required ensure-session "${code:-E_TOKEN_INVALID}" \
      "${detail:-the platform session itself needs an interactive sign-in}" \
      "${next:-the USER runs \`tireless-connect login\` in their OWN terminal, then replies done}"
    exit 1
    ;;
  fail)
    emit fail ensure-session "${code:-}" "${detail:-}" "${next:-}"
    exit 1
    ;;
  *)
    emit fail ensure-session "" \
      "unexpected output from tireless-connect ensure-session (exit $rc): $(oneline "$out")" \
      "run the fix skill's doctor step"
    exit 1
    ;;
esac
