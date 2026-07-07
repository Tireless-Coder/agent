#!/bin/sh
# clip-doctor.sh [workspace] — layered clipboard-bridge diagnosis, local
# first, then (with a workspace argument) the remote shim over ssh.
#
#   CLIP_BIN=ok|missing                  tireless-clip binary found
#   CLIP_CONFIG=ok|missing               ~/.ssh/tireless_clip_config exists
#   CLIP_INCLUDE=ok|missing              managed include markers in ~/.ssh/config
#   DAEMON=ok|dead|unknown               local daemon on 127.0.0.1:19985
#   REMOTE_SHIM=ok|missing|unreachable   (workspace arg only)
#   REMOTE_PNG=ok|none|unreachable       (workspace arg only)
#
# REMOTE_PNG=ok means an image really crossed the tunnel: the shim returned
# bytes starting with the PNG magic. "none" is deliberately ambiguous — an
# empty clipboard, a text-only clipboard, and a refused tunnel all look
# identical by design (TLCP REFUSED).
set -eu

BIN_DIR="$HOME/.local/bin"
SSH_CONFIG="$HOME/.ssh/config"
CLIP_CONFIG_FILE="$HOME/.ssh/tireless_clip_config"
WS="${1:-}"

CLIP_BIN=""
if command -v tireless-clip >/dev/null 2>&1; then
  CLIP_BIN="$(command -v tireless-clip)"
elif [ -x "$BIN_DIR/tireless-clip" ]; then
  CLIP_BIN="$BIN_DIR/tireless-clip"
fi
if [ -n "$CLIP_BIN" ]; then echo "CLIP_BIN=ok"; else echo "CLIP_BIN=missing"; fi

if [ -f "$CLIP_CONFIG_FILE" ]; then echo "CLIP_CONFIG=ok"; else echo "CLIP_CONFIG=missing"; fi

if grep -qsF '>>> tireless-clip managed include >>>' "$SSH_CONFIG"; then
  echo "CLIP_INCLUDE=ok"
else
  echo "CLIP_INCLUDE=missing"
fi

# TODO(live-verify): `tireless-clip status` exit semantics — assumed 0 when
# the local daemon answers the TLCP probe.
if [ -z "$CLIP_BIN" ]; then
  echo "DAEMON=unknown"
elif "$CLIP_BIN" status >/dev/null 2>&1; then
  echo "DAEMON=ok"
else
  echo "DAEMON=dead"
fi

if [ -n "$WS" ]; then
  # On a wired workspace, xclip resolves to the timeless-clip-shim symlink.
  # The remote command always exits 0 so a missing xclip is distinguishable
  # from an unreachable workspace.
  if shim="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$WS.tireless" 'p="$(command -v xclip || true)"; if [ -n "$p" ]; then readlink -f "$p"; else echo NO_XCLIP; fi' 2>/dev/null)"; then
    case "$shim" in
      *timeless-clip-shim*) echo "REMOTE_SHIM=ok" ;;
      *) echo "REMOTE_SHIM=missing" ;;
    esac
  else
    echo "REMOTE_SHIM=unreachable"
    echo "REMOTE_PNG=unreachable"
    exit 0
  fi
  # Behavioral probe: first 8 bytes of the clipboard as PNG. 89504e47 is the
  # PNG magic; anything else reports "none".
  if magic="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$WS.tireless" 'xclip -selection clipboard -t image/png -o 2>/dev/null | head -c 8 | od -An -tx1' 2>/dev/null)"; then
    case "$(printf '%s' "$magic" | tr -d ' \n')" in
      89504e47*) echo "REMOTE_PNG=ok" ;;
      *) echo "REMOTE_PNG=none" ;;
    esac
  else
    echo "REMOTE_PNG=unreachable"
  fi
fi
