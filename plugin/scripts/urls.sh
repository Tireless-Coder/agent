#!/bin/sh
# urls.sh <workspace> [slug|port] — rebuild the platform's deep-link shapes
# (mirrors packages/core/src/links.ts in the platform repo; Coder v2.24.x):
#
#   Subdomain app:  https://{slug}--main--{workspace}--{username}.{wildcard}/
#   Web terminal:   {cpUrl}/@{username}/{workspace}.main/terminal
#   VS Code:        vscode://vscode-remote/ssh-remote+{workspace}.tireless/home/dev
#   Cursor:         cursor://vscode-remote/ssh-remote+{workspace}.tireless/home/dev
#
# "main" is the single Coder agent name in the workspace template; /home/dev
# is the fixed workspace home dir. The username comes from
# `tireless users show me`. The wildcard app domain is not discoverable from
# the CLI — pass TIRELESS_WILDCARD_DOMAIN (e.g. eu.ws.tirelesscode.com) or
# take app links from the tireless_get_workspace connection card instead.
#
# Output is KEY=val; values that cannot be derived are the literal "unknown".
# Reserved ports are refused (APP=refused REASON=reserved-port): they ARE the
# workspace (sshd, code-server, desktop, clipboard), not a dev server on it.
set -eu

if [ "$#" -lt 1 ] || [ -z "$1" ]; then
  echo "usage: urls.sh <workspace> [slug|port]" >&2
  exit 2
fi
WS="$1"
TARGET="${2:-}"

BIN_DIR="$HOME/.local/bin"
CLI_BIN=""
if command -v tireless >/dev/null 2>&1; then
  CLI_BIN="$(command -v tireless)"
elif [ -x "$BIN_DIR/tireless" ]; then
  CLI_BIN="$BIN_DIR/tireless"
fi

# Coder CLI session files hold the control-plane URL the user logged in to.
# TODO(live-verify): stock Coder 2.24.2 keeps its config under "coderv2"
# (macOS: Application Support; Linux: XDG config dir).
CODER_DIR="${CODER_CONFIG_DIR:-}"
if [ -z "$CODER_DIR" ]; then
  if [ -d "$HOME/Library/Application Support/coderv2" ]; then
    CODER_DIR="$HOME/Library/Application Support/coderv2"
  else
    CODER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/coderv2"
  fi
fi
CP_URL=unknown
if [ -f "$CODER_DIR/url" ]; then
  CP_URL="$(head -n1 "$CODER_DIR/url" | tr -d '[:space:]')"
  CP_URL="${CP_URL%/}"
  if [ -z "$CP_URL" ]; then CP_URL=unknown; fi
fi

# TODO(live-verify): `tireless users show me -o json` field name on Coder
# 2.24.2 — assumed "username" at the top level.
USERNAME=unknown
if [ -n "$CLI_BIN" ]; then
  u="$("$CLI_BIN" users show me -o json 2>/dev/null | grep -o '"username"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 | cut -d'"' -f4 || true)"
  if [ -n "$u" ]; then USERNAME="$u"; fi
fi

echo "WS=$WS"
echo "SSH_ALIAS=$WS.tireless"
echo "USER=$USERNAME"
echo "CP_URL=$CP_URL"
echo "VSCODE=vscode://vscode-remote/ssh-remote+$WS.tireless/home/dev"
# NOTE(live-verify): Cursor's URI authority has varied across releases
# (cursor://vscode-remote/… vs cursor://anysphere.remote-ssh/…).
echo "CURSOR=cursor://vscode-remote/ssh-remote+$WS.tireless/home/dev"

if [ "$CP_URL" != unknown ] && [ "$USERNAME" != unknown ]; then
  echo "TERMINAL=$CP_URL/@$USERNAME/$WS.main/terminal"
else
  echo "TERMINAL=unknown"
fi

if [ -n "$TARGET" ]; then
  case "$TARGET" in
    22|13337|6800|6801|6810|19985)
      echo "APP=refused"
      echo "REASON=reserved-port"
      exit 1
      ;;
  esac
  WILDCARD="${TIRELESS_WILDCARD_DOMAIN:-}"
  if [ -n "$WILDCARD" ] && [ "$USERNAME" != unknown ]; then
    echo "APP=https://$TARGET--main--$WS--$USERNAME.$WILDCARD/"
  else
    echo "APP=unknown"
    echo "NOTE=set TIRELESS_WILDCARD_DOMAIN or use the tireless_get_workspace links"
  fi
fi
