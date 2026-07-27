#!/bin/sh
# verify.sh <workspace-or-alias> — end-to-end ssh probe of the workspace.
#
# Accepts either the connection card's full ssh_alias (anything containing a
# dot — used verbatim) or a bare workspace name, which is resolved against
# the regional suffixes the local ssh fragments define (legacy bare
# `.tireless` as last resort). BatchMode forbids interactive prompts (a hung
# prompt would stall the agent's Bash tool); ConnectTimeout bounds the wait.
# Output is KEY=val only:
#
#   VERIFY=ok|fail
#   ALIAS=<alias probed>         (ok only — feed this to later ssh commands)
#   HOST=<remote hostname>       (ok only)
#   SSH_EXIT=<code>              (fail only; 255 = ssh-level failure)
#   CAUSE=session_expired|no_session|unknown
#                                (fail only) why it failed, when we can tell.
#                                session_expired is ROUTINE (cells cap Coder
#                                sessions at 8h) and heals headlessly with
#                                `tireless-session-heal` — it is NOT a broken
#                                setup, and NOT something `tireless-connect
#                                setup` fixes on its own.
#   DETAIL=<most actionable stderr line>   (fail only)
set -eu

. "$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/alias.sh"

if [ "$#" -lt 1 ] || [ -z "$1" ]; then
  echo "usage: verify.sh <workspace-or-alias>" >&2
  exit 2
fi
WS="$1"

# Same interpolation-safety rule as the handoff scripts: WS ends up in ssh
# argv — constrain it to a safe charset instead of escaping heroics.
case "$WS" in -*|*[!a-zA-Z0-9.-]*)
  echo "verify.sh: workspace name has unsupported characters" >&2
  exit 2 ;;
esac

err_file="$(mktemp "${TMPDIR:-/tmp}/tireless-verify.XXXXXX")"
trap 'rm -f "$err_file"' EXIT

# Resolution IS a successful probe for bare names; a full alias still gets
# the explicit probe below so its failure detail is captured.
ALIAS="$(tireless_resolve_alias "$WS")" || {
  echo "VERIFY=fail"
  echo "SSH_EXIT=255"
  # An expired Coder session makes EVERY candidate alias fail to answer, so
  # resolution failure alone says nothing about the ssh config. Ask the
  # session what state it is in before naming a fix: telling the user to run
  # `tireless-connect setup` for an 8h expiry is advice that cannot work —
  # setup skips a region whose session is dead.
  cause=unknown
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    case "$(tireless_session_probe "$d")" in
      expired) cause=session_expired; break ;;
      missing) cause=no_session ;;
    esac
  done <<EOF
$(tireless_coder_dirs)
EOF
  echo "CAUSE=$cause"
  suffixes="$(tireless_ssh_suffixes | tr '\n' ' ')"
  if [ "$cause" = session_expired ]; then
    echo "DETAIL=no ssh alias for '$WS' answers because this machine's Coder session has expired (routine — cells cap them at 8h)"
    echo "NEXT=run tireless-session-heal (headless re-mint, no user action), then re-run this verify"
  else
    echo "DETAIL=no ssh alias for '$WS' answers (suffixes tried: ${suffixes:-none, plus legacy .tireless}) — run tireless_connect_workspace (or tireless-connect setup) to write the regional ssh config"
  fi
  exit 1
}

if out="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$ALIAS" 'echo TIRELESS_OK; hostname' 2>"$err_file")"; then
  case "$out" in
    TIRELESS_OK*)
      echo "VERIFY=ok"
      echo "ALIAS=$ALIAS"
      echo "HOST=$(printf '%s\n' "$out" | sed -n 2p)"
      exit 0
      ;;
  esac
  echo "VERIFY=fail"
  echo "SSH_EXIT=0"
  echo "DETAIL=unexpected output from remote shell"
  exit 1
else
  rc=$?
  echo "VERIFY=fail"
  echo "SSH_EXIT=$rc"
  # The ProxyCommand runs the tireless CLI, so an expired Coder session comes
  # back through ssh's stderr — but as the SECOND line, behind the CLI's
  # useless "Encountered an error running ..." banner. Taking line 1 blindly
  # threw away the only actionable sentence and left the agent guessing at a
  # connectivity fault: that misread is exactly why a routine 8h expiry used
  # to end in "workspace unreachable — run the fix skill".
  CAUSE=unknown
  if grep -qs 'session has expired' "$err_file"; then
    CAUSE=session_expired
  elif grep -qs 'not logged in' "$err_file"; then
    CAUSE=no_session
  fi
  echo "CAUSE=$CAUSE"
  detail="$(grep -v -e 'Encountered an error running' -e '^error: Trace=' -e '^[[:space:]]*$' "$err_file" 2>/dev/null | head -n1 | tr -d '\r')"
  if [ -z "$detail" ]; then
    detail="$(head -n1 "$err_file" 2>/dev/null | tr -d '\r')"
  fi
  echo "DETAIL=${detail:-none}"
  if [ "$CAUSE" = session_expired ]; then
    echo "NEXT=run tireless-session-heal (headless re-mint, no user action), then re-run this verify"
  fi
  exit 1
fi
