#!/bin/sh
# preflight.sh — deterministic environment snapshot for the tireless skills.
#
# Emits exactly one KEY=val line per check (no colors, no prose) so an agent
# can branch on string equality instead of parsing shell noise:
#
#   CLI=ok|missing         tireless CLI (rebranded Coder CLI) found
#   AUTH=ok|expired|error|missing
#                          the WORST verdict across regional Coder sessions
#                          (the only sessions the ssh configs actually use; the
#                          legacy default-dir probe is the last resort).
#                          expired = sessions were established here before and
#                          simply aged out (cells cap them at 8h, so this is
#                          the normal overnight state) — `tireless-session-heal`
#                          re-mints them headlessly, no user action needed.
#                          error   = the probe failed for a NON-auth reason
#                          (network, edge block, CLI crash) — do not heal.
#                          missing = nothing was ever set up on this machine.
#   AUTH_REGIONS=<region>:<verdict>,…|none
#                          the same verdict per cell, so a multi-cell account
#                          can see WHICH one is out instead of one rolled-up
#                          word
#   SSHCFG=ok|missing      a managed Include block (installer TIRELESS-CELLS
#                          or tireless-connect markers) is in ~/.ssh/config
#                          AND at least one regional fragment file exists
#   SSHCFG_STALE=yes|no    a stock Coder-branded block lingers in
#                          ~/.ssh/config from an old setup — it resolves
#                          nothing current
#   SSHCFG_STALE_OURS=yes|no|n/a
#                          yes = every ProxyCommand in it runs the Tireless
#                          CLI, so it is provably our own litter and
#                          `tireless-ssh-clean` removes it. no = it may belong
#                          to a real Coder deployment the user runs — report
#                          it, never touch it.
#   SSHCFG_STALE_LINES=<a-b,...>|none
#                          line ranges of the removable blocks
#   CLIP=ok|stale|missing  tireless-clip binary + managed ssh include wired
#   CONNECT=ok|missing     tireless-connect (MCP server binary) found
#   PATHOK=yes|no          ~/.local/bin is on PATH
#   APP_ORIGIN=<url>       platform origin (TIRELESS_APP_ORIGIN overrides)
#
# Read-only: probes never mutate state, so this script is safe to pre-approve.
set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
. "$SCRIPT_DIR/alias.sh"
. "$SCRIPT_DIR/sshscan.sh"

APP_ORIGIN="${TIRELESS_APP_ORIGIN:-https://app.tirelesscode.com}"
BIN_DIR="$HOME/.local/bin"
SSH_CONFIG="$HOME/.ssh/config"
CLIP_CONFIG="$HOME/.ssh/tireless_clip_config"

# The platform installer targets ~/.local/bin, which may not be on PATH yet —
# check both so a fresh install still reports CLI=ok.
CLI_BIN=""
if command -v tireless >/dev/null 2>&1; then
  CLI_BIN="$(command -v tireless)"
elif [ -x "$BIN_DIR/tireless" ]; then
  CLI_BIN="$BIN_DIR/tireless"
fi
if [ -n "$CLI_BIN" ]; then echo "CLI=ok"; else echo "CLI=missing"; fi

# Sessions live PER REGION under the state roots (installer:
# ~/.config/tireless/coder/<region>; connector:
# <UserConfigDir>/tireless-connect/coder/<region>) — a bare `tireless list`
# reads the stock coderv2 dir, which no supported setup ever writes. Probe
# every regional dir; fall back to the bare probe only for ancient installs.
#
# The probe now keeps the CLI's own stderr verdict instead of discarding it,
# because `expired` and `missing` demand opposite responses: expired heals
# headlessly with no user action, missing is onboarding. Reporting both as
# `missing` is what made a routine overnight expiry look like a broken
# install. `error` (network/edge/CLI) is kept separate too — healing into an
# outage is the wrong move.
# AUTH is the WORST verdict across regions, never the best. It used to be the
# best: any one region answering `ok` printed AUTH=ok, so a two-cell user whose
# us-east session had died read a clean bill of health while every
# `ssh ws.us-east.tireless` kept failing — and the fix skill's step 2, which
# would have healed it, was never reached. Per-region detail rides alongside in
# AUTH_REGIONS so a caller can tell WHICH cell is out.
#
# Severity order (highest wins): ok < expired < error, with `missing` carrying
# NO severity at all. That last part matters: the platform installer creates
# `~/.config/tireless/coder/<region>` unconditionally and never logs into it,
# and no heal ever touches that root — so counting `missing` as worse than
# `ok` made a perfectly healthy connector machine report AUTH=missing, which
# reads as "never set up" and sends an agent into onboarding. `missing` is
# reported only when NOTHING on this machine has a session.
AUTH=missing
AUTH_REGIONS=""
SEEN_ANY=no
if [ -n "$CLI_BIN" ]; then
  rank=0
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    SEEN_ANY=yes
    verdict="$(tireless_session_probe "$d")"
    AUTH_REGIONS="${AUTH_REGIONS:+$AUTH_REGIONS,}$(basename "$d"):$verdict"
    case "$verdict" in
      ok) r=1 ;;
      expired) r=2 ;;
      missing) r=0 ;;   # no information, never a verdict on its own
      *) r=3 ;;
    esac
    if [ "$r" -gt "$rank" ]; then
      rank=$r
      case "$verdict" in
        ok|expired) AUTH="$verdict" ;;
        *) AUTH=error ;;
      esac
    fi
  done <<EOF
$(tireless_coder_dirs)
EOF
  # Legacy single-region installs kept their session in the stock default dir.
  if [ "$SEEN_ANY" = no ] && "$CLI_BIN" list >/dev/null 2>&1; then AUTH=ok; fi
fi
echo "AUTH=$AUTH"
echo "AUTH_REGIONS=${AUTH_REGIONS:-none}"

# Both supported setups write a marker-wrapped Include in ~/.ssh/config and
# per-region fragments elsewhere — the Host lines are in the FRAGMENTS, so
# never grep ~/.ssh/config for them. Legacy fallback: a Host *.tireless line
# directly in ~/.ssh/config (pre-regional installs).
SSHCFG=missing
if [ -n "$(tireless_ssh_fragments)" ] \
  && grep -qsE 'START-TIRELESS-CELLS|>>> tireless-connect managed regional SSH include >>>' "$SSH_CONFIG"; then
  SSHCFG=ok
elif grep -qsE '^[[:space:]]*Host[[:space:]].*\.tireless([[:space:]]|$)' "$SSH_CONFIG"; then
  SSHCFG=ok
fi
echo "SSHCFG=$SSHCFG"

# Stale stock-Coder block. The scan (sshscan.sh) reads the block's own
# ProxyCommand rather than just its Host pattern, so a real Coder deployment
# the user actually uses is never mistaken for our litter.
STALE_SCAN="$(tireless_scan_stale_ssh "$(tireless_resolve_symlink "$SSH_CONFIG")")"
if [ -z "$STALE_SCAN" ]; then
  echo "SSHCFG_STALE=no"
  echo "SSHCFG_STALE_OURS=n/a"
  echo "SSHCFG_STALE_LINES=none"
else
  STALE_OURS=no
  STALE_LINES=""
  OLDIFS=$IFS; IFS='
'
  for row in $STALE_SCAN; do
    if [ "$(printf '%s\n' "$row" | awk '{print $4}')" = yes ]; then
      STALE_OURS=yes
      STALE_LINES="${STALE_LINES:+$STALE_LINES,}$(printf '%s\n' "$row" | awk '{print $2"-"$3}')"
    fi
  done
  IFS=$OLDIFS
  echo "SSHCFG_STALE=yes"
  echo "SSHCFG_STALE_OURS=$STALE_OURS"
  echo "SSHCFG_STALE_LINES=${STALE_LINES:-none}"
fi

CLIP_BIN=""
if command -v tireless-clip >/dev/null 2>&1; then
  CLIP_BIN="$(command -v tireless-clip)"
elif [ -x "$BIN_DIR/tireless-clip" ]; then
  CLIP_BIN="$BIN_DIR/tireless-clip"
fi
# ok = binary + regenerated include file + marker block in ~/.ssh/config;
# stale = binary present but `tireless-clip setup` has not (re)wired ssh.
if [ -z "$CLIP_BIN" ]; then
  echo "CLIP=missing"
elif [ -f "$CLIP_CONFIG" ] && grep -qsF '>>> tireless-clip managed include >>>' "$SSH_CONFIG"; then
  echo "CLIP=ok"
else
  echo "CLIP=stale"
fi

# tireless-connect may live on PATH or in the Claude plugin data dir (the
# plugin's launch-mcp.sh installs it there).
if command -v tireless-connect >/dev/null 2>&1 \
  || [ -x "${CLAUDE_PLUGIN_DATA:-$HOME/.claude/plugins/data/tireless}/bin/tireless-connect" ]; then
  echo "CONNECT=ok"
else
  echo "CONNECT=missing"
fi

case ":$PATH:" in
  *":$BIN_DIR:"*) echo "PATHOK=yes" ;;
  *) echo "PATHOK=no" ;;
esac

echo "APP_ORIGIN=$APP_ORIGIN"
