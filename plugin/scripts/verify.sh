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
#   DETAIL=<first stderr line>   (fail only — the most actionable line)
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
  suffixes="$(tireless_ssh_suffixes | tr '\n' ' ')"
  echo "DETAIL=no ssh alias for '$WS' answers (suffixes tried: ${suffixes:-none, plus legacy .tireless}) — run tireless_connect_workspace (or tireless-connect setup) to write the regional ssh config"
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
  detail="$(head -n1 "$err_file" 2>/dev/null | tr -d '\r')"
  echo "DETAIL=${detail:-none}"
  exit 1
fi
