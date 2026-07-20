#!/bin/sh
# preflight.sh — deterministic environment snapshot for the tireless skills.
#
# Emits exactly one KEY=val line per check (no colors, no prose) so an agent
# can branch on string equality instead of parsing shell noise:
#
#   CLI=ok|missing         tireless CLI (rebranded Coder CLI) found
#   AUTH=ok|missing        a REGIONAL Coder session answers `list` (the only
#                          sessions the ssh configs actually use; the legacy
#                          default-dir probe is the last resort)
#   SSHCFG=ok|missing      a managed Include block (installer TIRELESS-CELLS
#                          or tireless-connect markers) is in ~/.ssh/config
#                          AND at least one regional fragment file exists
#   SSHCFG_STALE=yes|no    a stock Coder-branded block (Host coder.* etc.)
#                          lingers in ~/.ssh/config from an old setup — it
#                          resolves nothing current; offer to clean it up
#   CLIP=ok|stale|missing  tireless-clip binary + managed ssh include wired
#   CONNECT=ok|missing     tireless-connect (MCP server binary) found
#   PATHOK=yes|no          ~/.local/bin is on PATH
#   APP_ORIGIN=<url>       platform origin (TIRELESS_APP_ORIGIN overrides)
#
# Read-only: probes never mutate state, so this script is safe to pre-approve.
set -eu

. "$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/alias.sh"

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
AUTH=missing
if [ -n "$CLI_BIN" ]; then
  while IFS= read -r d; do
    [ "$AUTH" = ok ] && continue
    if "$CLI_BIN" --global-config "$d" list >/dev/null 2>&1; then AUTH=ok; fi
  done <<EOF
$(tireless_coder_dirs)
EOF
  if [ "$AUTH" = missing ] && "$CLI_BIN" list >/dev/null 2>&1; then AUTH=ok; fi
fi
echo "AUTH=$AUTH"

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
if grep -qsE '^[[:space:]]*Host[[:space:]]+(coder\.\*|\*\.coder)([[:space:]]|$)' "$SSH_CONFIG"; then
  echo "SSHCFG_STALE=yes"
else
  echo "SSHCFG_STALE=no"
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
