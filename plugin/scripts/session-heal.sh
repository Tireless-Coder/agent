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
# It is deliberately NOT `tireless-connect login`: that command falls through
# to a loopback BROWSER flow when the platform token is also dead, which
# inside an agent's Bash tool means a hung call and a stalled session.
#
# Output is KEY=val; the FIRST line is SESSION=.
#
#   SESSION=ok               every region already had a live session
#   SESSION=healed           at least one region was re-minted (re-run what failed)
#   SESSION=action_required  only the user can fix this — CODE/NEXT say how
#   SESSION=fail             unexpected breakage — DETAIL says what
#   VIA=ensure-session|doctor|none   which connector path did the work
#   CODE=E_*                 fix code, matching the fix skill's map
#   DETAIL=<one line>        never contains a token
#   NEXT=<what to do next>
#
# Mutating (it writes the connector's own 0600 session files), so it stays
# prompt-gated — it is never added to a skill's pre-approved allowed-tools.
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

# Path 1 — the purpose-built headless entrypoint (connector >= 0.4.3).
out="$("$CONNECT" ensure-session 2>&1)" && rc=0 || rc=$?
case "$out" in
  *"unknown command"*)
    # Path 2 — older connector: `doctor` re-mints dead sessions as a side
    # effect of diagnosing them, and is equally browser-free. Older still and
    # it only diagnoses, which the coder_login row then tells us.
    #
    # doctor is unbounded by design (manifest fetch + reachability + 20s per
    # cell + mint + one heartbeat call per workspace, so it grows with the
    # account), and macOS ships no `timeout`. Bound it with a poll loop —
    # an agent's Bash call must never be the thing that discovers the limit.
    # </dev/null is belt-and-braces: nothing in doctor reads stdin, but the
    # guarantee belongs at the call site.
    doctor_out="$(mktemp "${TMPDIR:-/tmp}/tireless-doctor.XXXXXX")"
    "$CONNECT" doctor </dev/null >"$doctor_out" 2>&1 &
    dpid=$!
    waited=0
    while [ "$waited" -lt 90 ]; do
      kill -0 "$dpid" 2>/dev/null || break
      sleep 1
      waited=$((waited + 1))
    done
    if kill -0 "$dpid" 2>/dev/null; then
      kill "$dpid" 2>/dev/null || true
      rm -f "$doctor_out"
      emit fail doctor E_CODER_LOGIN \
        "tireless-connect doctor did not finish within 90s" \
        "re-run later, or the USER runs \`tireless-connect login\` in their OWN terminal"
      exit 1
    fi
    wait "$dpid" 2>/dev/null || true
    out="$(cat "$doctor_out")"
    rm -f "$doctor_out"
    if sessions_live; then
      emit healed doctor "" \
        "re-minted through the connector's doctor path (server-minted, no browser, no paste)" \
        "re-run whatever failed — the session is live again"
      exit 0
    fi
    detail="$(oneline "$(printf '%s\n' "$out" | grep -i 'coder_login' | head -1)")"
    emit action_required doctor E_CODER_LOGIN \
      "${detail:-this connector build cannot re-mint sessions headlessly}" \
      "update the connector (curl -fsSL https://app.tirelesscode.com/connect/install.sh | sh); if it still fails, the USER runs \`tireless-connect login\` in their OWN terminal and replies done"
    exit 1
    ;;
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
