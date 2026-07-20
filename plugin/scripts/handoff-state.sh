#!/bin/sh
# handoff-state.sh — read-only snapshot of the LOCAL repo for the continue
# skill (run it from inside the project being handed off).
#
# Emits exactly one KEY=val line per fact (no colors, no prose) so an agent
# can branch on string equality instead of parsing git output:
#
#   REPO=ok|none            inside a git work tree
#   REPO_ROOT=<abs path>    (ok only) toplevel — run handoff-sync from here
#   REPO_NAME=<basename>    (ok only) default remote project dir name
#   UNBORN=yes|no           repo has no commits yet (tar-mode territory)
#   DETACHED=yes|no         HEAD not on a branch (sync needs --branch)
#   BRANCH=<name>|none
#   HEAD_SHA=<sha>|none
#   DIRTY=<n>               tracked paths with uncommitted changes
#   UNTRACKED=<n>           untracked, not-ignored files
#   SUBMODULES=yes|no       .gitmodules present (contents do NOT travel)
#   LFS=yes|no              lfs filter in tracked .gitattributes (ditto)
#   ORIGIN_HOST=<host>|none host of the origin remote — never the full URL
#                           (https remotes can embed credentials)
#   ENV_CANDIDATES=<p1:p2>|none
#                           gitignored env-style files (.env*, .envrc) that
#                           git will NOT carry — candidates for --include
#
# Read-only: probes never mutate state, so this script is safe to pre-approve.
set -eu

# --is-inside-work-tree prints "false" (exit 0) in bare repos / .git dirs, so
# test the OUTPUT — an exit-status test would crash later with no output.
if [ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" != true ]; then
  echo "REPO=none"
  exit 0
fi

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
echo "REPO=ok"
echo "REPO_ROOT=$ROOT"
echo "REPO_NAME=$(basename "$ROOT")"

if git rev-parse -q --verify HEAD >/dev/null 2>&1; then
  echo "UNBORN=no"
  HEAD_SHA="$(git rev-parse HEAD)"
else
  echo "UNBORN=yes"
  HEAD_SHA=none
fi

BRANCH="$(git symbolic-ref --short -q HEAD || true)"
if [ -n "$BRANCH" ]; then
  echo "DETACHED=no"
  echo "BRANCH=$BRANCH"
else
  # An unborn HEAD also has no symbolic ref but is not "detached".
  if [ "$HEAD_SHA" = none ]; then echo "DETACHED=no"; else echo "DETACHED=yes"; fi
  echo "BRANCH=none"
fi
echo "HEAD_SHA=$HEAD_SHA"

# --porcelain: `??` lines are untracked, everything else is tracked changes.
STATUS="$(git status --porcelain)"
echo "DIRTY=$(printf '%s\n' "$STATUS" | grep -c '^[^?]' || true)"
echo "UNTRACKED=$(printf '%s\n' "$STATUS" | grep -c '^??' || true)"

if [ -f .gitmodules ]; then echo "SUBMODULES=yes"; else echo "SUBMODULES=no"; fi

LFS=no
OLDIFS=$IFS
IFS='
'
for f in $(git ls-files -- '*.gitattributes' 2>/dev/null); do
  if grep -qs 'filter=lfs' "$f"; then LFS=yes; break; fi
done
IFS=$OLDIFS
echo "LFS=$LFS"

ORIGIN_URL="$(git remote get-url origin 2>/dev/null || true)"
# scheme://user@host:port/path or scp-like user@host:path — strip scheme and
# userinfo, cut at the first : or /. Local-path remotes have no host.
case "$ORIGIN_URL" in
  ''|/*|./*|../*|file://*) HOST="" ;;
  *) HOST="$(printf '%s' "$ORIGIN_URL" \
    | sed -e 's#^[A-Za-z0-9+]*://##' -e 's#^[^@/]*@##' -e 's#[:/].*$##')" ;;
esac
echo "ORIGIN_HOST=${HOST:-none}"

# Gitignored env-style files. --directory collapses fully-ignored dirs
# (node_modules et al) so this stays fast and cannot surface their contents.
CANDIDATES=""
OLDIFS=$IFS
IFS='
'
for f in $(git ls-files --others --ignored --exclude-standard --directory 2>/dev/null); do
  base="$(basename "$f")"
  case "$base" in
    *.example|*.sample|*.template|*.dist) continue ;;
  esac
  case "$base" in
    .env|.env.*|.envrc) CANDIDATES="${CANDIDATES:+$CANDIDATES:}$f" ;;
  esac
done
IFS=$OLDIFS
echo "ENV_CANDIDATES=${CANDIDATES:-none}"

# Pending handoffs: records handoff-sync wrote for THIS repo that no pull has
# resolved yet — the workspace may hold work local lacks. Surface them so the
# agent runs `tireless-handoff-check` before local edits (see continue skill).
#   PENDING_HANDOFFS=<n>       unresolved records for this repo
#   PENDING_WS=<ws1[:ws2...]>|none  workspaces those records point at
PENDING=0
PENDING_WS=""
ROOT_ID="$(printf '%s' "$ROOT" | cksum | awk '{print $1}')"
for rec in "$HOME/.timeless/handoffs/out/"*"--$ROOT_ID.rec"; do
  [ -f "$rec" ] || continue
  [ "$(sed -n 's/^RESOLVED=//p' "$rec" | head -1)" = yes ] && continue
  PENDING=$((PENDING + 1))
  ws="$(sed -n 's/^WS=//p' "$rec" | head -1)"
  PENDING_WS="${PENDING_WS:+$PENDING_WS:}$ws"
done
echo "PENDING_HANDOFFS=$PENDING"
echo "PENDING_WS=${PENDING_WS:-none}"
