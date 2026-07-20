#!/bin/sh
# urls.sh <workspace> [slug|port] — rebuild the platform's deep-link shapes
# (mirrors packages/core/src/links.ts in the platform repo; Coder v2.x):
#
#   Subdomain app:  https://{slug}--main--{workspace}--{username}.{wildcard}/
#   Web terminal:   {cpUrl}/@{username}/{workspace}.main/terminal
#   Claude Code:    claude-cli://open?q={prefilled Tireless connection request}
#   VS Code:        vscode://vscode-remote/ssh-remote+{alias}/home/dev/{workspace}
#   Cursor:         cursor://vscode-remote/ssh-remote+{alias}/home/dev/{workspace}
#
# {alias} is the REAL ssh alias (resolved via the regional fragments, e.g.
# myws.eu-central.tireless), and the control-plane URL + username come from
# the REGIONAL Coder session dirs the setups actually write — never the stock
# coderv2 dir. The authoritative source remains the links object from
# tireless_get_workspace / tireless_connect_workspace; this script is the
# no-MCP fallback.
#
# "main" is the single Coder agent name in the workspace template; projects
# live in /home/dev/{workspace}. The wildcard app domain is not discoverable
# from the CLI — pass TIRELESS_WILDCARD_DOMAIN (e.g. eu.ws.tirelesscode.com)
# or take app links from the connection card instead.
#
# Output is KEY=val; values that cannot be derived are the literal "unknown".
# Reserved ports are refused (APP=refused REASON=reserved-port): they ARE the
# workspace (sshd, code-server, desktop, clipboard), not a dev server on it.
set -eu

. "$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/alias.sh"

if [ "$#" -lt 1 ] || [ -z "$1" ]; then
  echo "usage: urls.sh <workspace> [slug|port]" >&2
  exit 2
fi
WS="$1"
TARGET="${2:-}"
# Links want the bare workspace name for paths; an alias argument still works
# (first label = workspace name).
WS_NAME="${WS%%.*}"

BIN_DIR="$HOME/.local/bin"
CLI_BIN=""
if command -v tireless >/dev/null 2>&1; then
  CLI_BIN="$(command -v tireless)"
elif [ -x "$BIN_DIR/tireless" ]; then
  CLI_BIN="$BIN_DIR/tireless"
fi

# Control-plane URL + username from the first regional session dir that has
# them (CODER_CONFIG_DIR overrides; legacy stock dirs last).
CP_URL=unknown
USERNAME=unknown
try_coder_dir() {
  [ -f "$1/url" ] || return 0
  [ "$CP_URL" = unknown ] || return 0
  u="$(head -n1 "$1/url" | tr -d '[:space:]')"
  u="${u%/}"
  [ -n "$u" ] || return 0
  CP_URL="$u"
  if [ -n "$CLI_BIN" ]; then
    un="$("$CLI_BIN" --global-config "$1" users show me -o json 2>/dev/null \
      | grep -o '"username"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 | cut -d'"' -f4 || true)"
    [ -n "$un" ] && USERNAME="$un"
  fi
}
if [ -n "${CODER_CONFIG_DIR:-}" ]; then try_coder_dir "$CODER_CONFIG_DIR"; fi
while IFS= read -r d; do
  try_coder_dir "$d"
done <<EOF
$(tireless_coder_dirs)
EOF
try_coder_dir "$HOME/Library/Application Support/coderv2"
try_coder_dir "${XDG_CONFIG_HOME:-$HOME/.config}/coderv2"

ALIAS="$(tireless_resolve_alias "$WS" 2>/dev/null)" || ALIAS="$WS_NAME.tireless"

echo "WS=$WS_NAME"
echo "SSH_ALIAS=$ALIAS"
echo "USER=$USERNAME"
echo "CP_URL=$CP_URL"
enc_alias="$ALIAS"
echo "CLAUDE=claude-cli://open?q=Connect%20to%20my%20Tireless%20workspace%20$WS_NAME%20and%20work%20in%20%2Fhome%2Fdev%2F$WS_NAME.%20Use%20the%20Tireless%20plugin%20when%20available%3B%20otherwise%20use%20the%20native%20SSH%20alias%20$enc_alias%20and%20keep%20every%20command%20and%20file%20operation%20on%20the%20remote%20workspace."
echo "VSCODE=vscode://vscode-remote/ssh-remote+$ALIAS/home/dev/$WS_NAME"
# NOTE(live-verify): Cursor's URI authority has varied across releases
# (cursor://vscode-remote/… vs cursor://anysphere.remote-ssh/…).
echo "CURSOR=cursor://vscode-remote/ssh-remote+$ALIAS/home/dev/$WS_NAME"

if [ "$CP_URL" != unknown ] && [ "$USERNAME" != unknown ]; then
  echo "TERMINAL=$CP_URL/@$USERNAME/$WS_NAME.main/terminal"
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
    echo "APP=https://$TARGET--main--$WS_NAME--$USERNAME.$WILDCARD/"
  else
    echo "APP=unknown"
    echo "NOTE=set TIRELESS_WILDCARD_DOMAIN or use the tireless_get_workspace links"
  fi
fi
