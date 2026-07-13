#!/bin/sh
# handoff-launch.sh <workspace> <target-dir> [--agent claude|codex]
#                   [--session NAME] [--status | --stop]
# Start (or inspect/stop) the continued agent session on the workspace,
# inside a detached tmux session seeded with a FIXED kickoff prompt pointing
# at ~/.timeless/handoffs/latest.md. All task-specific content lives in the
# brief file — never on this command line — so the quoting stays
# deterministic (the load-bearing rule of this script).
#
# Launch output (KEY=val):
#   LAUNCH=ok|exists|blocked|fail
#   AGENT=claude|codex         (ok)
#   REASON=not_installed|unauth|no_target_dir   (blocked)
#   REMOTE_CONTROL=on|off      whether claude.ai remote steering is active
#   SESSION=<tmux session>     ATTACH_SSH=<one-liner>       (ok/exists)
#   HINT=...                   next step for blocked outcomes
#   DETAIL=...                 (fail) unexpected breakage — switch to fix skill
# --status output:
#   STATUS=running|ended       plus the last pane lines on stdout
# --stop output:
#   STOPPED=yes|no
#
# The claude launch passes --dangerously-skip-permissions (per-product
# decision: the workspace is the user's own single-tenant VM) and
# --remote-control so the session is steerable from claude.ai/code and the
# mobile app. TODO(live-verify): --remote-control flag on the pinned recipe
# build (2.1.197, docs say >=2.1.51) — if the first launch dies instantly the
# script retries once without it and reports REMOTE_CONTROL=off. Codex has no
# CLI->web visibility mechanism at 0.144.x; its steering path is tmux attach.
set -eu

SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=10"
KICKOFF='Read ~/.timeless/handoffs/latest.md. It is a handoff brief from another agent session. Verify the project state it describes, then continue the work. Do not retry anything listed under Dead ends.'

usage() {
  echo "usage: handoff-launch.sh <workspace> <target-dir> [--agent claude|codex] [--session NAME] [--status|--stop]" >&2
  exit 2
}

fail() {
  echo "LAUNCH=fail"
  echo "DETAIL=$1"
  exit 1
}

[ $# -ge 2 ] || usage
WS="$1"; TARGET_DIR="$2"; shift 2
AGENT=claude
SESSION=tireless-continue
MODE=launch
while [ $# -gt 0 ]; do
  case "$1" in
    --agent) [ $# -ge 2 ] || usage; AGENT="$2"; shift ;;
    --session) [ $# -ge 2 ] || usage; SESSION="$2"; shift ;;
    --status) MODE=status ;;
    --stop) MODE=stop ;;
    *) usage ;;
  esac
  shift
done

case "$WS" in ''|-*|*[!a-zA-Z0-9-]*) fail "workspace name has unsupported characters" ;; esac
case "$TARGET_DIR" in /*) ;; *) fail "target dir must be absolute" ;; esac
case "$TARGET_DIR" in *[!a-zA-Z0-9/._-]*) fail "target dir has unsupported characters" ;; esac
case "$SESSION" in ''|*[!a-zA-Z0-9_-]*) fail "session name has unsupported characters" ;; esac
case "$AGENT" in claude|codex) ;; *) fail "unsupported agent '$AGENT' (claude|codex)" ;; esac

rsh() {
  # shellcheck disable=SC2086
  ssh $SSH_OPTS "$WS.tireless" "$@"
}

# Every mode needs a reachable workspace; without this gate an ssh-level
# failure (exit 255) is indistinguishable from "no tmux session".
rsh 'echo TIRELESS_OK' 2>/dev/null | grep -q TIRELESS_OK \
  || fail "workspace unreachable over ssh — run the fix skill"

# Probe that separates "session alive/gone" from "ssh broke mid-flight".
session_state() {
  rsh "sleep ${1:-0}; tmux has-session -t '$SESSION' 2>/dev/null && echo ALIVE || echo GONE" 2>/dev/null || true
}

if [ "$MODE" = status ]; then
  case "$(session_state 0)" in
    ALIVE)
      echo "STATUS=running"
      rsh "tmux capture-pane -pt '$SESSION' -S -100 | tail -50" || true
      ;;
    GONE) echo "STATUS=ended" ;;
    *) fail "workspace unreachable over ssh — run the fix skill" ;;
  esac
  exit 0
fi

if [ "$MODE" = stop ]; then
  if rsh "tmux kill-session -t '$SESSION' 2>/dev/null"; then
    echo "STOPPED=yes"
  else
    echo "STOPPED=no"
  fi
  exit 0
fi

# ---- prechecks ---------------------------------------------------------------
rsh "test -d '$TARGET_DIR'" || { echo "LAUNCH=blocked"; echo "REASON=no_target_dir"; echo "HINT=run tireless-handoff-sync first"; exit 1; }

case "$AGENT" in
  claude)
    BIN='$HOME/.local/bin/claude'
    BYPASS='--dangerously-skip-permissions'
    ;;
  codex)
    BIN='$HOME/.local/bin/codex'
    BYPASS='--dangerously-bypass-approvals-and-sandbox'
    ;;
esac

if ! rsh "test -x \"$BIN\""; then
  echo "LAUNCH=blocked"
  echo "REASON=not_installed"
  echo "HINT=install the $AGENT recipe from the dashboard (workspace page > Recipes), then re-run"
  exit 1
fi

# Auth probe. claude: `auth status --json` when available, credentials file as
# the weaker fallback (existence != validity). codex: auth.json only.
# TODO(live-verify): `claude auth status --json` output shape on 2.1.197.
AUTH=missing
if [ "$AGENT" = claude ]; then
  out="$(rsh "\"\$HOME/.local/bin/claude\" auth status --json 2>/dev/null" || true)"
  if printf '%s' "$out" | grep -q '"loggedIn":[[:space:]]*true'; then
    AUTH=ok
  elif rsh 'test -s "$HOME/.claude/.credentials.json"'; then
    AUTH=ok
  fi
else
  if rsh 'test -s "$HOME/.codex/auth.json"'; then AUTH=ok; fi
fi
if [ "$AUTH" != ok ]; then
  echo "LAUNCH=blocked"
  echo "REASON=unauth"
  echo "HINT=one-time sign-in: open the workspace web terminal, run $AGENT, follow the login flow (never paste tokens into chat), then re-run"
  exit 1
fi

if [ "$(session_state 0)" = ALIVE ]; then
  echo "LAUNCH=exists"
  echo "SESSION=$SESSION"
  echo "ATTACH_SSH=ssh -t $WS.tireless tmux attach -t $SESSION"
  echo "HINT=attach to it, or re-run with --stop first to replace it"
  exit 0
fi

# ---- launch --------------------------------------------------------------------
# The runner is written to a remote file first (printf | cat, per
# reference/remote-exec.md) so only ONE quoting layer exists per hop. $HOME
# stays escaped: it must expand on the workspace, not here.
write_runner() {
  # $1 = extra flags for the agent binary
  printf '%s\n' \
    '#!/bin/sh' \
    'set -eu' \
    "cd '$TARGET_DIR'" \
    "exec tmux new-session -d -s '$SESSION' -x 220 -y 50 \"$BIN $BYPASS $1 '$KICKOFF'\"" \
    | rsh 'mkdir -p "$HOME/.timeless/handoffs" && cat > "$HOME/.timeless/handoffs/launch.sh"' \
    || fail "could not write the launch runner on the workspace"
}

REMOTE_CONTROL=off
if [ "$AGENT" = claude ]; then
  write_runner '--remote-control'
  rsh 'sh "$HOME/.timeless/handoffs/launch.sh"' || fail "tmux launch failed"
  # An unsupported flag kills the process immediately; a healthy session
  # survives its first seconds. Retry once without remote control.
  case "$(session_state 3)" in
    ALIVE) REMOTE_CONTROL=on ;;
    GONE)
      write_runner ''
      rsh 'sh "$HOME/.timeless/handoffs/launch.sh"' || fail "tmux launch failed"
      case "$(session_state 3)" in
        ALIVE) ;;
        GONE) fail "the agent session exits immediately — run $AGENT attended in the web terminal to see why (likely expired login), then re-run" ;;
        *) fail "lost ssh while verifying the launch — run the fix skill, then re-run with --status" ;;
      esac
      ;;
    *) fail "lost ssh while verifying the launch — run the fix skill, then re-run with --status" ;;
  esac
else
  write_runner ''
  rsh 'sh "$HOME/.timeless/handoffs/launch.sh"' || fail "tmux launch failed"
  case "$(session_state 3)" in
    ALIVE) ;;
    GONE) fail "the agent session exits immediately — run $AGENT attended in the web terminal to see why (likely expired login), then re-run" ;;
    *) fail "lost ssh while verifying the launch — run the fix skill, then re-run with --status" ;;
  esac
fi

echo "LAUNCH=ok"
echo "AGENT=$AGENT"
echo "SESSION=$SESSION"
echo "REMOTE_CONTROL=$REMOTE_CONTROL"
echo "ATTACH_SSH=ssh -t $WS.tireless tmux attach -t $SESSION"
