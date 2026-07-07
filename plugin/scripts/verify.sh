#!/bin/sh
# verify.sh <workspace> — end-to-end ssh probe of the workspace alias.
#
# BatchMode forbids interactive prompts (a hung prompt would stall the
# agent's Bash tool); ConnectTimeout bounds the wait. Output is KEY=val only:
#
#   VERIFY=ok|fail
#   HOST=<remote hostname>       (ok only)
#   SSH_EXIT=<code>              (fail only; 255 = ssh-level failure)
#   DETAIL=<first stderr line>   (fail only — the most actionable line)
set -eu

if [ "$#" -lt 1 ] || [ -z "$1" ]; then
  echo "usage: verify.sh <workspace>" >&2
  exit 2
fi
WS="$1"

err_file="${TMPDIR:-/tmp}/tireless-verify.$$"
trap 'rm -f "$err_file"' EXIT

if out="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$WS.tireless" 'echo TIRELESS_OK; hostname' 2>"$err_file")"; then
  case "$out" in
    TIRELESS_OK*)
      echo "VERIFY=ok"
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
