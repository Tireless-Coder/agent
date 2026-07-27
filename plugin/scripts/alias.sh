# shellcheck shell=sh
# alias.sh — sourced helpers shared by the tireless scripts: where the two
# supported setups actually keep state, and how to turn a bare workspace name
# into an ssh alias that resolves TODAY.
#
# Ground truth (verified against the platform installer route.ts and
# tireless-connect setup.go): neither setup writes Host entries into
# ~/.ssh/config directly. Both write marker-wrapped Include blocks there
# pointing at per-region fragment files whose Host patterns end in
# `.<region>.tireless`:
#   installer:  ~/.config/tireless/ssh/<region>.config
#               (markers: # ------------START-TIRELESS-CELLS------------)
#   connector:  <UserConfigDir>/tireless-connect/ssh/<region>.config
#               (markers: # >>> tireless-connect managed regional SSH include >>>)
# Coder sessions live per region next to them, under <root>/coder/<region>.
# The bare `<ws>.tireless` alias is a legacy single-region shape — keep it as
# the LAST fallback only.

# Every state root that may exist on this machine, one per line (paths can
# contain spaces — iterate with `while read`, never `for`).
tireless_state_roots() {
  printf '%s\n' "$HOME/.config/tireless"
  if [ "$(uname 2>/dev/null)" = Darwin ]; then
    printf '%s\n' "$HOME/Library/Application Support/tireless-connect"
  fi
  printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/tireless-connect"
}

# Regional ssh fragment files that exist, one path per line.
tireless_ssh_fragments() {
  tireless_state_roots | while IFS= read -r root; do
    for f in "$root/ssh/"*.config; do
      [ -f "$f" ] && printf '%s\n' "$f"
    done
  done
}

# Distinct host suffixes (e.g. eu-central.tireless) from the fragments'
# `Host *.<suffix>` / `Match host *.<suffix>` lines, one per line.
tireless_ssh_suffixes() {
  tireless_ssh_fragments | while IFS= read -r f; do
    sed -n -e 's/^[[:space:]]*Host[[:space:]]\{1,\}\*\.\([A-Za-z0-9][A-Za-z0-9.-]*tireless\)[[:space:]]*$/\1/p' \
      -e 's/^[[:space:]]*Match[[:space:]]\{1,\}host[[:space:]]\{1,\}\*\.\([A-Za-z0-9][A-Za-z0-9.-]*tireless\).*$/\1/p' "$f"
  done | sort -u
}

# tireless_resolve_symlink <path> — echo the final target of a symlink chain
# (bounded). Anything that BACKS UP one file and then rewrites it must resolve
# first, or it backs up the target and replaces the link — silently detaching
# a dotfiles repo, or turning a CLAUDE.md -> AGENTS.md symlink into two
# diverging files. macOS `readlink` has no portable -f, hence the loop.
tireless_resolve_symlink() {
  _p="$1"
  _n=0
  while [ -L "$_p" ] && [ "$_n" -lt 16 ]; do
    _t="$(readlink "$_p")" || break
    case "$_t" in
      /*) _p="$_t" ;;
      *) _p="$(dirname "$_p")/$_t" ;;
    esac
    _n=$((_n + 1))
  done
  printf '%s\n' "$_p"
}

# tireless_run_bounded <seconds> <stderr-file> <cmd> [args…] — run a command
# with a hard wall-clock bound, discarding stdout and capturing stderr.
# Returns the command's status, or non-zero if it had to be killed.
# POSIX-only: macOS has no `timeout`/`gtimeout`, so this is a watchdog on a
# background job.
tireless_run_bounded() {
  _limit="$1"; _errfile="$2"; shift 2
  "$@" >/dev/null 2>"$_errfile" &
  _pid=$!
  _waited=0
  while [ "$_waited" -lt "$_limit" ]; do
    kill -0 "$_pid" 2>/dev/null || break
    sleep 1
    _waited=$((_waited + 1))
  done
  if kill -0 "$_pid" 2>/dev/null; then
    kill "$_pid" 2>/dev/null || true
    wait "$_pid" 2>/dev/null || true
    return 124
  fi
  wait "$_pid" 2>/dev/null
}

# tireless_cli_bin — the `tireless` CLI, on PATH or at the installer's target.
# Echoes nothing and returns 1 when it is not installed.
tireless_cli_bin() {
  if command -v tireless >/dev/null 2>&1; then
    command -v tireless
  elif [ -x "$HOME/.local/bin/tireless" ]; then
    printf '%s\n' "$HOME/.local/bin/tireless"
  else
    return 1
  fi
}

# tireless_session_probe <coder-global-config-dir> — classify one regional
# Coder session in ONE word: ok | expired | missing | error | no_cli.
#
# The distinction is the whole point. A cell caps sessions at 8h with no
# sliding refresh, so `expired` is the normal state of a laptop that slept —
# routine, heals headlessly, no user action. `missing` means this machine was
# never connected (onboarding). `error` is a network/edge/CLI problem and must
# NEVER be treated as expiry: minting into an outage just hammers the platform
# and mislabels the failure.
#
# The two literal strings are the Coder CLI's own messages, verified against
# the shipped binary (v2.34.5) on 2026-07-27.
#
# Bounded: the probe runs inside pre-approved, read-only commands
# (`tireless-preflight`, `tireless-verify`) whose whole promise is that they
# return promptly. A control plane that accepts the TCP connection and then
# stalls would otherwise hang them for minutes, so the CLI gets a hard
# deadline. macOS ships no `timeout`, hence the watchdog subshell.
TIRELESS_PROBE_TIMEOUT="${TIRELESS_PROBE_TIMEOUT:-25}"
tireless_session_probe() {
  _cli="$(tireless_cli_bin)" || { printf 'no_cli\n'; return 0; }
  _err="$(mktemp "${TMPDIR:-/tmp}/tireless-sess.XXXXXX")"
  if tireless_run_bounded "$TIRELESS_PROBE_TIMEOUT" "$_err" \
    "$_cli" --global-config "$1" list; then
    printf 'ok\n'
  elif grep -qs 'session has expired' "$_err"; then
    printf 'expired\n'
  elif grep -qs 'not logged in' "$_err"; then
    printf 'missing\n'
  else
    printf 'error\n'
  fi
  rm -f "$_err"
}

# Regional Coder session dirs (each usable as `tireless --global-config DIR`),
# one per line.
tireless_coder_dirs() {
  tireless_state_roots | while IFS= read -r root; do
    for d in "$root/coder/"*/; do
      [ -d "$d" ] && printf '%s\n' "${d%/}"
    done
  done
}

# tireless_session_expired — read-only: does ANY regional session report the
# definitive `expired` verdict? Safe inside a pre-approved probe; it mints
# nothing and writes nothing.
tireless_session_expired() {
  while IFS= read -r _d; do
    [ -n "$_d" ] || continue
    if [ "$(tireless_session_probe "$_d")" = expired ]; then return 0; fi
  done <<EOF
$(tireless_coder_dirs)
EOF
  return 1
}

# tireless_heal_once — re-mint expired regional Coder sessions, at most once
# per script invocation. Returns 0 when something was healed (so the caller
# should retry), 1 otherwise.
#
# CALL IT DIRECTLY — never inside `$( … )`. Command substitution runs a
# subshell, so the once-per-invocation guard below would be set in a copy and
# lost, turning "heal at most once" into "heal on every call".
#
# The mutating handoff scripts call this instead of failing with "workspace
# unreachable": they are already prompt-gated, so healing inline costs no new
# approval surface, and an 8h expiry mid-handoff is common enough that
# aborting on it wastes a whole turn. Guards, in order:
#   - once per process (a shell variable, not a state file — the repo's only
#     retry precedent, handoff-launch.sh, does the same)
#   - only on a DEFINITIVE `expired` verdict; `error` (network, edge block)
#     never triggers a mint
#   - a 2-minute FAILURE-only cooldown file, so a probe→heal→probe loop across
#     invocations cannot hammer the mint route. Failure-only matters: a stale
#     or deleted cooldown file can never cause a wrong RESULT, only an extra
#     attempt.
TIRELESS_HEAL_TRIED=0
tireless_heal_once() {
  [ "$TIRELESS_HEAL_TRIED" = 0 ] || return 1
  TIRELESS_HEAL_TRIED=1

  tireless_session_expired || return 1

  _cool="$HOME/.timeless/heal-cooldown"
  if [ -f "$_cool" ] && [ -n "$(find "$_cool" -mmin -2 2>/dev/null)" ]; then
    return 1
  fi

  # $0 is the SOURCING script (alias.sh is only ever sourced), so its dirname
  # is the scripts dir; TIRELESS_SCRIPTS_DIR overrides for odd invocations.
  _dir="${TIRELESS_SCRIPTS_DIR:-$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)}"
  _heal="$_dir/session-heal.sh"
  [ -f "$_heal" ] || return 1
  if sh "$_heal" 2>/dev/null | grep -q '^SESSION=healed'; then
    return 0
  fi
  mkdir -p "$HOME/.timeless" 2>/dev/null || true
  : >"$_cool" 2>/dev/null || true
  return 1
}

# tireless_resolve_alias <workspace-or-alias> — echo an ssh alias that
# answers, probing candidates with a fast BatchMode ssh. An argument that
# already contains a dot is trusted as a full alias (the connection card's
# ssh_alias). Returns 1 when nothing answers.
tireless_resolve_alias() {
  case "$1" in
    *.*) printf '%s\n' "$1"; return 0 ;;
  esac
  _suffixes="$(tireless_ssh_suffixes)"
  for _sfx in $_suffixes tireless; do
    if ssh -o BatchMode=yes -o ConnectTimeout=10 "$1.$_sfx" 'echo TIRELESS_OK' 2>/dev/null | grep -q TIRELESS_OK; then
      printf '%s.%s\n' "$1" "$_sfx"
      return 0
    fi
  done
  return 1
}
