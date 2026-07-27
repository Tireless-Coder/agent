#!/bin/sh
# PreToolUse(Bash) hook — renew a nearly-dead Coder session in the moment
# BEFORE the command that would have failed on it.
#
# SessionStart warming alone leaves the obvious hole: a session that starts at
# 07:00 of the cell token's 7h59m life crosses the boundary an hour into the
# conversation, long after any startup hook ran. That mid-task crossing is
# exactly the 2026-07-27 incident, and the command it breaks is the agent's own
# `ssh <workspace>.tireless …` — our code is nowhere in that path, so this hook
# is the last place we can act while acting still helps.
#
# Deliberately SYNCHRONOUS, unlike the startup warm. Backgrounding would race
# the very command we were called for; blocking for the ~2s a re-mint takes
# means the command then works. The cost is bounded on both axes:
#   - it exits before touching the filesystem unless the command mentions
#     tireless at all, so the ordinary Bash call pays one string match
#   - past that, staleness is a stat per region, and the heal only runs when
#     the mint is over 7h old — at most once per session lifetime
#
# Never blocks a tool call: exit 0 on every path, including a failed heal
# (the fix skill handles a genuinely broken connection; a hook must not be the
# thing that decides an agent cannot run a command).
set -u

[ "${TIRELESS_NO_AUTOHEAL:-0}" = 1 ] && exit 0

# The hook payload is JSON on stdin. Matching the raw text is deliberate: it
# needs no parser, and a false positive here costs one stat.
input="$(cat 2>/dev/null || true)"

# Gate on the COMMAND, never on the whole payload: `cwd` and `transcript_path`
# are always present, so payload matching opens this hook for every Bash call
# made anywhere under a path containing "tireless".
command="$(printf '%s' "$input" | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
case "$command" in
  *tireless*|*" ssh "*|ssh\ *) ;;
  *) exit 0 ;;
esac

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)/scripts"
. "$SCRIPT_DIR/alias.sh"

tireless_warm_due || exit 0
tireless_warm_mark

out="$(sh "$SCRIPT_DIR/session-heal.sh" 2>&1)" || true

# PreToolUse stdout is NOT context — for this event Claude Code writes plain
# stdout to the debug log only (verified against the hook reference,
# 2026-07-27; SessionStart and UserPromptSubmit are the exceptions, which is
# why the sibling hooks may just printf). The documented way to reach the model
# without blocking the call is hookSpecificOutput.additionalContext. No
# permissionDecision is emitted: this hook renews a credential, it has no
# opinion about whether the command may run.
say() {
  # One line, no double quotes, no backslashes — the cheapest way to stay valid
  # JSON without a serializer.
  _m="$(printf '%s' "$1" | tr '\n\r"\\' "  ''" | sed -e 's/  */ /g')"
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"%s"}}\n' "$_m"
}

case "$out" in
  SESSION=healed*)
    say "[tireless] The per-cell Coder session your workspace ssh uses was about to expire (cells cap it at 8h with no refresh) and was just re-minted headlessly — no browser, no paste, no user action. Your command should work now; if it already failed on auth, retry it once and carry on without making it a topic."
    ;;
  SESSION=action_required*)
    say "[tireless] The per-cell Coder session is spent and could NOT be re-minted headlessly, because the PLATFORM sign-in also needs the user. Heal output: $out -- relay its NEXT line to the user. Do not run 'tireless-connect login' from your own shell: it can open a browser and block until it times out."
    ;;
esac
exit 0
