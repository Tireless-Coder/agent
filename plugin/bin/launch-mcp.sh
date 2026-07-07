#!/bin/sh
# launch-mcp.sh — stdio launcher for the tireless MCP server (Claude plugin).
#
# stdout IS the MCP stdio channel: nothing may be written to it before the
# final exec or the client's JSON-RPC framing breaks. All diagnostics go to
# stderr.
#
# Resolution order: tireless-connect on PATH, then the plugin's persistent
# data dir. If the binary is missing — or older than the platform's published
# minimum (GET /api/agent/version) — download the current build from the
# stable public URL and atomically install it into ${CLAUDE_PLUGIN_DATA}/bin,
# so the plugin stays genuinely "one thing" to install.
set -eu

log() { printf 'tireless: %s\n' "$*" >&2; }

APP_ORIGIN="${TIRELESS_APP_ORIGIN:-https://tirelesscode.com}"
# CLAUDE_PLUGIN_DATA persists across plugin updates; the fallback matches
# Claude Code's documented data-dir layout in case the variable is unset.
DATA_DIR="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/plugins/data/tireless}"
BIN_DIR="$DATA_DIR/bin"
MANAGED_BIN="$BIN_DIR/tireless-connect"

case "$(uname -s)" in
  Darwin) os=darwin ;;
  Linux) os=linux ;;
  *) log "unsupported OS '$(uname -s)' — tireless-connect ships for macOS and Linux"; exit 1 ;;
esac
case "$(uname -m)" in
  arm64|aarch64) arch=arm64 ;;
  x86_64|amd64) arch=amd64 ;;
  *) log "unsupported architecture '$(uname -m)'"; exit 1 ;;
esac

BIN=""
if command -v tireless-connect >/dev/null 2>&1; then
  BIN="$(command -v tireless-connect)"
elif [ -x "$MANAGED_BIN" ]; then
  BIN="$MANAGED_BIN"
fi

# 0 when $1 is a strictly lower version than $2 (x.y.z numeric compare).
ver_lt() {
  if [ "$1" = "$2" ]; then return 1; fi
  lowest="$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | head -n1)"
  [ "$lowest" = "$1" ]
}

# Staleness check against the version manifest. Network failures are
# tolerated: a connected-but-stale binary beats no MCP server at all.
NEED_DOWNLOAD=0
if [ -z "$BIN" ]; then
  NEED_DOWNLOAD=1
else
  manifest="$(curl -fsS --max-time 5 "$APP_ORIGIN/api/agent/version" 2>/dev/null || true)"
  min="$(printf '%s' "$manifest" | grep -o '"min"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 | cut -d'"' -f4 || true)"
  if [ -n "$min" ]; then
    # TODO(live-verify): `tireless-connect version` output format — the first
    # x.y.z in its output is assumed to be the binary version.
    current="$("$BIN" version 2>/dev/null | grep -o '[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*' | head -n1 || true)"
    if [ -z "$current" ] || ver_lt "$current" "$min"; then
      NEED_DOWNLOAD=1
    fi
  fi
fi

if [ "$NEED_DOWNLOAD" = 1 ]; then
  url="$APP_ORIGIN/connect/bin/$os-$arch"
  log "downloading tireless-connect ($os/$arch) from $url"
  mkdir -p "$BIN_DIR"
  tmp="$BIN_DIR/.tireless-connect.$$"
  if curl -fsSL "$url" -o "$tmp"; then
    chmod 0755 "$tmp"
    # Same-directory rename: atomic swap, never a half-written binary.
    mv -f "$tmp" "$MANAGED_BIN"
    BIN="$MANAGED_BIN"
  else
    rm -f "$tmp"
    if [ -n "$BIN" ]; then
      log "download failed — continuing with the existing binary at $BIN"
    else
      log "download failed and no existing binary found — run: curl -fsSL $APP_ORIGIN/connect/install.sh | sh"
      exit 1
    fi
  fi
fi

exec "$BIN" mcp
