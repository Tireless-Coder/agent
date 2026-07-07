#!/bin/sh
# preflight.sh — deterministic environment snapshot for the tireless skills.
#
# Emits exactly one KEY=val line per check (no colors, no prose) so an agent
# can branch on string equality instead of parsing shell noise:
#
#   CLI=ok|missing         tireless CLI (rebranded Coder CLI) found
#   AUTH=ok|missing        `tireless list` exits 0 (Coder session valid)
#   SSHCFG=ok|missing      *.tireless host block present in ~/.ssh/config
#   CLIP=ok|stale|missing  tireless-clip binary + managed ssh include wired
#   CONNECT=ok|missing     tireless-connect (MCP server binary) found
#   PATHOK=yes|no          ~/.local/bin is on PATH
#   APP_ORIGIN=<url>       platform origin (TIRELESS_APP_ORIGIN overrides)
#
# Read-only: probes never mutate state, so this script is safe to pre-approve.
set -eu

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

# `tireless list` exiting 0 is the same already-signed-in probe the platform
# installer uses; non-zero means no session (or CP unreachable — the fix
# skill separates the two).
if [ -n "$CLI_BIN" ] && "$CLI_BIN" list >/dev/null 2>&1; then
  echo "AUTH=ok"
else
  echo "AUTH=missing"
fi

# `tireless config-ssh --yes` writes a Coder-managed block whose Host pattern
# ends in the .tireless suffix. The tireless-clip `Host *.tireless` line lives
# in ~/.ssh/tireless_clip_config (a separate Include file), so it cannot
# false-positive this grep. TODO(live-verify): exact managed-block markers on
# Coder 2.24.2 — the Host pattern is the stable observable.
if grep -qsE '^[[:space:]]*Host[[:space:]].*\.tireless([[:space:]]|$)' "$SSH_CONFIG"; then
  echo "SSHCFG=ok"
else
  echo "SSHCFG=missing"
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
