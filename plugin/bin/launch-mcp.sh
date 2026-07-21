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
# stable public URL, verify the SHA256SUMS manifest against the ECDSA release
# signature (public key pinned in this plugin, a trust root independent of the
# download origin), check the binary against the signed manifest, and
# atomically install it into ${CLAUDE_PLUGIN_DATA}/bin, so the plugin stays
# genuinely "one thing" to install.
set -eu

log() { printf 'tireless: %s\n' "$*" >&2; }

APP_ORIGIN="${TIRELESS_APP_ORIGIN:-https://app.tirelesscode.com}"
# CLAUDE_PLUGIN_DATA persists across plugin updates; the fallback matches
# Claude Code's documented data-dir layout in case the variable is unset.
DATA_DIR="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/plugins/data/tireless}"
BIN_DIR="$DATA_DIR/bin"
MANAGED_BIN="$BIN_DIR/tireless-connect"
# Release public key, shipped with the plugin (installed from the reviewed
# GitHub repo) — NOT fetched from the download origin, so a compromised
# origin/bucket alone cannot push a binary that verifies.
PUBKEY="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)/share/release-pub.pem"

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

# 0 when $1 is a strictly lower version than $2 (x.y.z numeric compare).
ver_lt() {
  if [ "$1" = "$2" ]; then return 1; fi
  lowest="$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | head -n1)"
  [ "$lowest" = "$1" ]
}

version_of() {
  "$1" version 2>/dev/null | grep -o '[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*' | head -n1 || true
}

# Prefer whichever installed copy is newer. This avoids re-downloading into
# the managed data dir on every launch when an older PATH copy also exists,
# while still letting a newer development build on PATH win.
PATH_BIN=""
if command -v tireless-connect >/dev/null 2>&1; then
  PATH_BIN="$(command -v tireless-connect)"
fi
BIN=""
if [ -n "$PATH_BIN" ] && [ -x "$MANAGED_BIN" ]; then
  path_version="$(version_of "$PATH_BIN")"
  managed_version="$(version_of "$MANAGED_BIN")"
  if [ -n "$managed_version" ] && { [ -z "$path_version" ] || ver_lt "$path_version" "$managed_version"; }; then
    BIN="$MANAGED_BIN"
  else
    BIN="$PATH_BIN"
  fi
elif [ -n "$PATH_BIN" ]; then
  BIN="$PATH_BIN"
elif [ -x "$MANAGED_BIN" ]; then
  BIN="$MANAGED_BIN"
fi

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
    current="$(version_of "$BIN")"
    if [ -z "$current" ] || ver_lt "$current" "$min"; then
      NEED_DOWNLOAD=1
    fi
  fi
fi

# sha256 of a file, portable across darwin (shasum) and linux (sha256sum).
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

if [ "$NEED_DOWNLOAD" = 1 ]; then
  url="$APP_ORIGIN/connect/bin/$os-$arch"
  log "downloading tireless-connect ($os/$arch) from $url"
  mkdir -p "$BIN_DIR"
  tmp="$BIN_DIR/.tireless-connect.$$"
  sums="$BIN_DIR/.tireless-sums.$$"
  sig="$BIN_DIR/.tireless-sums.sig.$$"
  ok=0
  if curl -fsSL "$url" -o "$tmp" \
    && curl -fsSL "$APP_ORIGIN/connect/bin/SHA256SUMS" -o "$sums" \
    && curl -fsSL "$APP_ORIGIN/connect/bin/SHA256SUMS.sig" -o "$sig"; then
    # Authenticity gate: the checksum manifest must carry a valid ECDSA
    # signature from the pinned release key (above), then the binary hash is
    # checked against the signed manifest. Fail closed — an unverifiable
    # download never runs.
    if [ ! -f "$PUBKEY" ]; then
      log "release public key missing ($PUBKEY) — refusing the downloaded binary"
    elif ! command -v openssl >/dev/null 2>&1; then
      log "openssl unavailable — cannot verify the release signature, refusing the download"
    elif ! openssl dgst -sha256 -verify "$PUBKEY" -signature "$sig" "$sums" >/dev/null 2>&1; then
      log "manifest signature invalid — refusing the downloaded binary"
    else
      expected="$(awk -v n="tireless-connect-$os-$arch" '$2 == n { print $1 }' "$sums")"
      if [ -z "$expected" ]; then
        log "no manifest entry for tireless-connect-$os-$arch — refusing the downloaded binary"
      elif [ "$(sha256_of "$tmp")" != "$expected" ]; then
        log "checksum mismatch for tireless-connect-$os-$arch — refusing the downloaded binary"
      else
        ok=1
      fi
    fi
  fi
  rm -f "$sums" "$sig"
  if [ "$ok" = 1 ]; then
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
