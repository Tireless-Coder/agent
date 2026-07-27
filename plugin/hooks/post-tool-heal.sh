#!/bin/sh
# PostToolUseFailure(Bash) hook — when a Tireless command fails on AUTH, repair
# it and say so, in the moment, next to the failure.
#
# The warming hooks handle expiry by the clock, which covers the common case.
# This covers everything else: a token revoked server-side, an account switch,
# a session that died between the pre-check and the command, a machine whose
# session predates expiry tracking, a clock that is wrong. In all of those the
# agent sees the same thing — a raw two-line Coder banner in its own Bash
# output — and on 2026-07-27 what it did with that was invent a theory,
# refresh the wrong auth layer twice, and report to the user that they were
# signed out. There is no reason for an agent to guess about this: the failure
# text is unambiguous, and the repair is one server-side call.
#
# Output goes through hookSpecificOutput.additionalContext, which for
# PostToolUseFailure is delivered next to the tool result (verified against the
# hook reference, 2026-07-27). Plain stdout would only reach the debug log.
#
# Never blocks and never fails a tool call: no `decision` field is emitted and
# every path exits 0. If the payload turns out not to carry the error text on
# some client version, the auth match simply never fires and the staleness
# fallback below still covers the ordinary expiry — i.e. it degrades to the
# behavior we had before this hook existed, never to something worse.
set -u

[ "${TIRELESS_NO_AUTOHEAL:-0}" = 1 ] && exit 0

input="$(cat 2>/dev/null || true)"
case "$input" in
  *tireless*) ;;
  *) exit 0 ;;
esac

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)/scripts"
. "$SCRIPT_DIR/alias.sh"

say() {
  _m="$(printf '%s' "$1" | tr '\n\r"\\' "  ''" | sed -e 's/  */ /g')"
  printf '{"hookSpecificOutput":{"hookEventName":"PostToolUseFailure","additionalContext":"%s"}}\n' "$_m"
}

# Auth-shaped failure? These are the CLI's and coderd's own words. Anything
# else — a failing test suite, a missing file, a broken build on the workspace
# — is none of this hook's business, and healing on it would burn the mint
# route on failures that have nothing to do with auth.
auth_shaped=no
case "$input" in
  *"session has expired"*|*"You are signed out"*|*"not logged in"*|*"no longer logged in"*|*"Try logging in"*|*"401"*)
    auth_shaped=yes ;;
esac

# ROUTING-shaped failure — the OTHER way a Tireless ssh dies, and the one that
# looks least like itself. When the regional ssh config is missing, stale or
# shadowed, OpenSSH never reaches the proxy: it treats the alias as a real
# hostname and fails in DNS. Nothing in that message mentions Tireless, Coder,
# sessions or auth, so it reads like a typo or a dead box — and the repair is
# a completely different command from the auth one.
route_shaped=no
case "$input" in
  *"Could not resolve hostname"*|*"nodename nor servname"*|*"Name or service not known"*|*"No such host is known"*)
    route_shaped=yes ;;
esac

# A forced heal needs its own short cooldown: the fingerprint guard used by the
# warming hooks is keyed to the clock, and this path deliberately ignores the
# clock. Two minutes is enough that a command retried in a loop cannot turn
# into a mint loop, and short enough to be invisible to a human.
COOL="$HOME/.timeless/heal-forced"
forced_ok() {
  [ -f "$COOL" ] && [ -n "$(find "$COOL" -mmin -2 2>/dev/null)" ] && return 1
  mkdir -p "$(dirname "$COOL")" 2>/dev/null || return 1
  : >"$COOL" 2>/dev/null || return 1
  return 0
}

if [ "$route_shaped" = yes ] && [ "$auth_shaped" = no ]; then
  forced_ok || exit 0
  out="$(sh "$SCRIPT_DIR/ssh-repair.sh" 2>&1)" || true
  case "$out" in
    SSHFIX=repaired*)
      say "[tireless] That host did not resolve because this machine's regional Tireless ssh config was stale — it has just been regenerated. RETRY the command, using the FULL alias <workspace>.<region>.tireless (the bare <workspace>.tireless form is legacy and resolves to nothing on a regional install). This is a local config repair, not a workspace problem."
      ;;
    SSHFIX=ok*)
      say "[tireless] The Tireless ssh config is intact, so that hostname failing to resolve is NOT a stale-config problem. The most likely cause is the alias itself: use the FULL <workspace>.<region>.tireless form from the connection card (tireless_get_workspace / tireless_connect_workspace), never the bare <workspace>.tireless."
      ;;
    *)
      say "[tireless] That host did not resolve and the automatic ssh-config repair did not complete. Repair output: $out -- follow the fix skill's E_SSH_BLOCK row."
      ;;
  esac
  exit 0
fi


if [ "$auth_shaped" = yes ]; then
  forced_ok || exit 0
elif tireless_warm_due; then
  tireless_warm_mark
else
  exit 0
fi

out="$(sh "$SCRIPT_DIR/session-heal.sh" 2>&1)" || true
case "$out" in
  SESSION=healed*)
    say "[tireless] That command failed because the per-cell Coder session had expired — cells cap it at 8h with no refresh, so it happens about daily and means nothing is wrong with the workspace or the setup. It has just been re-minted headlessly (server-minted, no browser, no paste, no user action). RETRY the exact command; do not diagnose further, do not call tireless_status or tireless_login about it, and do not tell the user they are signed out."
    ;;
  SESSION=ok*)
    say "[tireless] The per-cell Coder session is live, so auth is NOT why that command failed — do not re-run any session repair. Diagnose the actual error, or use the fix skill if the connection itself looks wrong."
    ;;
  SESSION=action_required*)
    say "[tireless] That command failed on auth, and the session could NOT be re-minted headlessly because the PLATFORM sign-in also needs the user. Heal output: $out -- relay its NEXT line to the user verbatim. Do not run 'tireless-connect login' from your own shell: it can open a browser and block until it times out."
    ;;
  SESSION=fail*)
    say "[tireless] That command failed on auth and the automatic re-mint also failed. Heal output: $out -- follow the fix skill for that code. Do not retry the heal blindly."
    ;;
esac
exit 0
