#!/bin/sh
# Tireless Agent Connector — multi-client installer (Codex, Cursor).
#
# Claude Code users never need this script; the Claude plugin is:
#   claude plugin marketplace add tirelesscode/agent && claude plugin install tireless@tireless
# and its bundled launcher self-installs the tireless-connect binary.
#
# Modes:
#   --codex        install for Codex (skills + ~/.codex/AGENTS.md block)
#   --cursor       install for Cursor (skills + .cursor/rules/tireless.mdc)
#   --all          both
#   --skills-only  skip the tireless-connect binary + `init` step (used by
#                  the platform's /connect/install.sh, which has already
#                  installed the binary and written the MCP configs)
# Default: auto-detect clients by config-dir presence (~/.codex, ~/.cursor).
#
# Idempotent: skills are refreshed wholesale under ~/.agents/skills/tireless;
# AGENTS.md gets ONE marker-delimited block (never duplicated on re-run); the
# Cursor rule file is rewritten in place.
set -eu

APP_ORIGIN="${TIRELESS_APP_ORIGIN:-https://tirelesscode.com}"
TAR_URL="${TIRELESS_AGENT_TAR_URL:-https://codeload.github.com/tirelesscode/agent/tar.gz/refs/heads/main}"
SKILLS_DEST="$HOME/.agents/skills/tireless"
BIN_DIR="$HOME/.local/bin"
MARK_BEGIN="# >>> tireless agent connector >>>"
MARK_END="# <<< tireless agent connector <<<"

DO_CODEX=0
DO_CURSOR=0
SKILLS_ONLY=0
EXPLICIT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --codex) DO_CODEX=1; EXPLICIT=1 ;;
    --cursor) DO_CURSOR=1; EXPLICIT=1 ;;
    --all) DO_CODEX=1; DO_CURSOR=1; EXPLICIT=1 ;;
    --skills-only) SKILLS_ONLY=1 ;;
    *) echo "error: unknown flag '$1' (flags: --codex --cursor --all --skills-only)" >&2; exit 1 ;;
  esac
  shift
done

if [ "$EXPLICIT" = 0 ]; then
  if [ -d "$HOME/.codex" ]; then DO_CODEX=1; fi
  if [ -d "$HOME/.cursor" ]; then DO_CURSOR=1; fi
  if [ "$DO_CODEX" = 0 ] && [ "$DO_CURSOR" = 0 ]; then
    echo "[!]  no ~/.codex or ~/.cursor found — installing skills only (use --codex/--cursor/--all to force)"
  fi
fi

case "$(uname -s)" in
  Darwin|Linux) ;;
  MINGW*|MSYS*|CYGWIN*|Windows_NT)
    echo "error: Windows client setup ships next — use the dashboard editors and Paste page meanwhile." >&2
    exit 1 ;;
  *) echo "error: unsupported OS '$(uname -s)'." >&2; exit 1 ;;
esac

# Resolve the source tree: a local checkout when run from the repo, else a
# fresh tarball (`curl | sh` has no checkout to read from).
CLEANUP=""
trap 'if [ -n "$CLEANUP" ]; then rm -rf "$CLEANUP"; fi' EXIT
script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" 2>/dev/null && pwd || true)"
if [ -n "$script_dir" ] && [ -d "$script_dir/plugin/skills" ]; then
  SRC="$script_dir"
else
  workdir="$(mktemp -d)"
  CLEANUP="$workdir"
  echo "[..] fetching skills from tirelesscode/agent"
  curl -fsSL "$TAR_URL" | tar -xz -C "$workdir"
  SRC="$(find "$workdir" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  if [ -z "$SRC" ] || [ ! -d "$SRC/plugin/skills" ]; then
    echo "error: could not fetch the tirelesscode/agent source tree." >&2
    exit 1
  fi
fi

# 1. tireless-connect binary + MCP config, unless the platform installer
#    (which owns that part of the chain) already did it.
if [ "$SKILLS_ONLY" = 0 ]; then
  case "$(uname -m)" in
    arm64|aarch64) arch=arm64 ;;
    x86_64|amd64) arch=amd64 ;;
    *) echo "error: unsupported architecture '$(uname -m)'." >&2; exit 1 ;;
  esac
  case "$(uname -s)" in
    Darwin) os=darwin ;;
    *) os=linux ;;
  esac
  if command -v tireless-connect >/dev/null 2>&1; then
    echo "[ok] tireless-connect already installed"
    CONNECT_BIN="$(command -v tireless-connect)"
  else
    echo "[..] installing tireless-connect ($os/$arch)"
    mkdir -p "$BIN_DIR"
    curl -fsSL "$APP_ORIGIN/connect/bin/$os-$arch" -o "$BIN_DIR/tireless-connect"
    chmod 0755 "$BIN_DIR/tireless-connect"
    CONNECT_BIN="$BIN_DIR/tireless-connect"
  fi
  # init is idempotent: parse-modify-write for JSON, marker-delimited append
  # for TOML — it never clobbers unrelated keys.
  echo "[..] writing MCP config (tireless-connect init)"
  "$CONNECT_BIN" init --client auto || echo "[!]  init failed — run: tireless-connect init --client auto"
fi

# 2. Skills (shared by Codex and Cursor; both read SKILL.md natively).
echo "[..] installing skills to $SKILLS_DEST"
mkdir -p "$SKILLS_DEST"
for d in connect fix workspace clipboard; do
  rm -rf "${SKILLS_DEST:?}/$d"
  cp -R "$SRC/plugin/skills/$d" "$SKILLS_DEST/$d"
done
for d in scripts reference; do
  rm -rf "${SKILLS_DEST:?}/$d"
  cp -R "$SRC/plugin/$d" "$SKILLS_DEST/$d"
done
chmod 0755 "$SKILLS_DEST/scripts/"*.sh

# 3. Codex: one marker-delimited block in ~/.codex/AGENTS.md.
if [ "$DO_CODEX" = 1 ]; then
  mkdir -p "$HOME/.codex"
  agents_md="$HOME/.codex/AGENTS.md"
  if grep -qsF "$MARK_BEGIN" "$agents_md"; then
    echo "[ok] ~/.codex/AGENTS.md already has the tireless block"
  else
    # Blank-line separator only when appending to existing content; the size
    # test happens before the redirection opens the file for append.
    if [ -s "$agents_md" ]; then printf '\n' >>"$agents_md"; fi
    {
      printf '%s\n' "$MARK_BEGIN"
      cat "$SRC/agents/AGENTS.snippet.md"
      printf '%s\n' "$MARK_END"
    } >>"$agents_md"
    echo "[ok] appended tireless block to ~/.codex/AGENTS.md"
  fi
fi

# 4. Cursor: project rule file (auto-attached). Rewritten wholesale — the
#    file is ours, so overwrite beats duplicate-detection.
if [ "$DO_CURSOR" = 1 ]; then
  rules_dir="$PWD/.cursor/rules"
  mkdir -p "$rules_dir"
  {
    printf -- '---\n'
    printf 'description: Tireless cloud dev computer — connect, remote exec over ssh <workspace>.tireless, lifecycle guardrails\n'
    printf 'alwaysApply: true\n'
    printf -- '---\n\n'
    cat "$SRC/agents/AGENTS.snippet.md"
    printf '\nFull skills: ~/.agents/skills/tireless/ (connect, fix, workspace, clipboard).\n'
  } >"$rules_dir/tireless.mdc"
  echo "[ok] wrote $rules_dir/tireless.mdc"
fi

echo ""
echo "[done] Now tell your agent: \"connect to my workspace\""
