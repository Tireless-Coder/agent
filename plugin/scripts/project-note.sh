#!/bin/sh
# project-note.sh <alias> <target-dir> <branch> [--dir PROJECT_DIR] [--remove]
#   — write (or refresh) the Tireless remote-exec stanza in THIS project's
#     agent memory file, so the next session in this repo drives the workspace
#     correctly instead of rediscovering the rules.
#
# Called automatically by handoff-sync.sh after a successful sync: the moment
# a project's code lives on a workspace, every later session in that project
# needs the same handful of facts (the alias, the remote dir, cd-prefixing,
# tmux for long jobs, how to bring the work back). Asking "shall I add a note
# to CLAUDE.md?" after every sync was pure ceremony — the answer is always yes.
#
# Targets, in order: every CLAUDE.md / AGENTS.md that already exists at the
# project root, else a new CLAUDE.md. The block is marker-wrapped and REPLACED
# in place on later syncs, so a changed alias or target dir updates rather
# than accumulating. Backups go to ~/.timeless/handoffs/note-backups/ — never
# beside the file, where they would show up as untracked repo junk.
#
# Output is KEY=val; the FIRST line is NOTE=.
#
#   NOTE=written|updated|removed|unchanged|skipped|fail
#   FILES=<comma-separated names at the project root>
#   TRACKED=yes|no       the file is under git control, so this edit shows up
#                        as a diff and can be committed and pushed to
#                        teammates — the stanza names a machine-specific ssh
#                        alias, so SAY SO when reporting to the user
#   BACKUP=<path|none>   pre-change copy of the last file changed
#   DETAIL=<one line>    only when skipped/fail
set -eu

. "$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/alias.sh"

MARK_BEGIN='<!-- >>> tireless workspace >>> -->'
MARK_END='<!-- <<< tireless workspace <<< -->'

usage() {
  echo "usage: project-note.sh <ssh-alias> <target-dir> <branch> [--dir PROJECT_DIR] [--remove]" >&2
  exit 2
}

# Every exit path emits the full documented key set. A caller that parses
# FILES=/TRACKED= must never receive an empty value, and a failure AFTER some
# files were already rewritten has to disclose what changed and where the
# backup is — otherwise the undo path is unknowable.
FILES=""
BACKUP=none
TRACKED=no

report() {
  echo "NOTE=$1"
  echo "FILES=${FILES:-none}"
  echo "TRACKED=$TRACKED"
  echo "BACKUP=$BACKUP"
  if [ -n "${2:-}" ]; then echo "DETAIL=$2"; fi
}

fail() { report fail "$1"; exit 1; }

# set -eu turns any unguarded failure (a full disk on the temp write, an
# unwritable backup dir) into a bare non-zero exit with NO output at all,
# which breaks the "first line is NOTE=" contract exactly when a caller most
# needs to know what happened. Convert that into a reported failure.
on_unexpected_exit() {
  st=$?
  if [ "$st" != 0 ] && [ "$REPORTED" = 0 ]; then
    report fail "aborted unexpectedly (exit $st) — see any BACKUP above to restore"
  fi
  if [ -n "$TMP" ]; then rm -f "$TMP"; fi
}
REPORTED=0
TMP=""
trap on_unexpected_exit EXIT

[ $# -ge 3 ] || usage
ALIAS="$1"; TARGET_DIR="$2"; BRANCH="$3"; shift 3
PROJECT_DIR="$PWD"
REMOVE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) [ $# -ge 2 ] || usage; PROJECT_DIR="$2"; shift ;;
    --remove) REMOVE=1 ;;
    *) usage ;;
  esac
  shift
done

# These land inside a file the user reads and an agent obeys — hold them to
# the same safe charset handoff-sync already enforces on its own arguments.
case "$ALIAS" in ''|-*|*[!a-zA-Z0-9.-]*) fail "unsupported characters in ssh alias" ;; esac
case "$BRANCH" in ''|*[!a-zA-Z0-9/._-]*) fail "unsupported characters in branch name" ;; esac
case "$TARGET_DIR" in /*) ;; *) fail "target dir must be absolute" ;; esac
case "$TARGET_DIR" in *[!a-zA-Z0-9/._-]*) fail "unsupported characters in target dir" ;; esac
[ -d "$PROJECT_DIR" ] || fail "no such project directory: $PROJECT_DIR"

TS="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="$HOME/.timeless/handoffs/note-backups"

# Which files to touch: every agent-memory file that already exists, else a
# new CLAUDE.md. Creating BOTH would be presumptuous — a Codex-only project
# has no use for CLAUDE.md, and vice versa.
TARGETS=""
for f in CLAUDE.md AGENTS.md; do
  if [ -f "$PROJECT_DIR/$f" ]; then TARGETS="${TARGETS:+$TARGETS }$f"; fi
done
if [ -z "$TARGETS" ]; then
  if [ "$REMOVE" = 1 ]; then
    REPORTED=1; report unchanged; exit 0
  fi
  TARGETS="CLAUDE.md"
fi

# The stanza. Deliberately short: it is read into context every session, so
# every line has to earn its place. Everything here is something an agent gets
# WRONG by default — fresh-shell cd-prefixing above all.
render_block() {
  cat <<EOF
$MARK_BEGIN
## Tireless workspace

This project is synced to the Tireless cloud workspace \`$ALIAS\` at
\`$TARGET_DIR\` (branch \`$BRANCH\`). If you are reading this ON that
workspace, you are already inside it — ignore the ssh instructions and work
on the local files.

- Run remote commands with plain ssh: \`ssh $ALIAS 'cd $TARGET_DIR && <cmd>'\`.
  Every ssh call is a FRESH login shell in \$HOME — always cd-prefix; no
  directory, environment or shell state survives between calls.
- Probes: add \`-o BatchMode=yes -o ConnectTimeout=10\` so nothing can hang.
- Jobs over ~2 minutes: \`tmux new -d -s <name> '<cmd> 2>&1 | tee ~/<name>.log'\`,
  then poll the log. Cap every remote output with \`| tail -100\`.
- Read/Grep/Glob see only LOCAL files. Read remote files over ssh
  (\`sed -n 1,120p <path>\`) instead of copying the tree down.
- Send newer local work up with \`tireless-handoff-sync\`; bring the
  workspace's work back with \`tireless-handoff-check\` then
  \`tireless-handoff-pull\`. Don't edit both sides at once.
- Never run \`tireless start|stop|delete|create\` or mutate the workspace via
  the Coder API — lifecycle belongs to the Tireless dashboard and the
  \`tireless_workspace_action\` tool (restart/suspend/resume only).

Written by tireless-handoff-sync. Safe to delete or edit; the next sync
rewrites only what is between the markers.
$MARK_END
EOF
}

WROTE=0; UPDATED=0; REMOVED=0

# Is this file under git control? A tracked CLAUDE.md means our stanza — which
# names a machine-specific ssh alias and a path that only exists on one
# workspace — becomes a commitable diff that could be pushed to teammates.
# We still write it (it is marker-wrapped and one line to delete), but the
# caller has to be able to TELL the user, so this is surfaced, not swallowed.
is_tracked() {
  git -C "$PROJECT_DIR" ls-files --error-unmatch "$1" >/dev/null 2>&1
}

SEEN_PATHS=""
for f in $TARGETS; do
  # Resolve first: CLAUDE.md is often a symlink to AGENTS.md (or into a
  # dotfiles repo). Writing through the link name would replace the link with
  # a regular file and leave the two contents diverging from then on.
  path="$(tireless_resolve_symlink "$PROJECT_DIR/$f")"
  case "$SEEN_PATHS" in
    *"|$path|"*) continue ;;  # CLAUDE.md and AGENTS.md are the same file
  esac
  SEEN_PATHS="$SEEN_PATHS|$path|"
  had_block=no
  # -x: whole line, matching the stripper's rule. A marker quoted inside prose
  # must not make us believe our block is present.
  if [ -f "$path" ] && grep -qsxF "$MARK_BEGIN" "$path"; then had_block=yes; fi
  if [ "$REMOVE" = 1 ] && [ "$had_block" = no ]; then continue; fi

  # A begin marker with no end marker means the file was hand-edited mid-block.
  # Rewriting it would swallow whatever the user put there — stop instead.
  if [ "$had_block" = yes ] && ! grep -qsxF "$MARK_END" "$path"; then
    # Anything already rewritten in an earlier loop iteration stays in
    # FILES/BACKUP, so the caller can still see and undo it.
    FILES="${FILES:+$FILES,}$f"
    REPORTED=1
    report skipped "$f has an unterminated tireless block (begin marker, no end marker) — left untouched so nothing of yours is lost"
    exit 0
  fi

  TMP="$path.tireless-tmp-$$"
  # Seed the temp file FROM the target so it inherits the target's mode, then
  # truncate (truncation does not change mode). Creating it fresh would give
  # it the caller's umask, and the `mv` below would then quietly widen a
  # deliberately private 0600 CLAUDE.md to 0644. No portable
  # `chmod --reference` exists, hence the copy-then-truncate.
  if [ -f "$path" ]; then
    cp -p "$path" "$TMP" || fail "could not stage a rewrite of $f"
  fi
  : >"$TMP"
  if [ -f "$path" ]; then
    # Drop the old block, and with it the single blank separator line we
    # inserted above it — otherwise every refresh grows a blank line.
    # WHOLE-LINE marker match, never a substring. A doc that merely QUOTES
    # the marker — this repo's own reference/handoff.md does — would
    # otherwise start the deletion at that sentence and run to the real end
    # marker, silently eating everything between. Trailing CR is trimmed so
    # a CRLF file matches too.
    awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
      {
        line = $0
        sub(/\015$/, "", line)
        gsub(/^[[:blank:]]+|[[:blank:]]+$/, "", line)
        if (!drop && line == b) {
          drop = 1
          if (pend && prev ~ /^[[:blank:]]*$/) pend = 0
        }
        if (drop) { if (line == e) drop = 0; next }
        if (pend) print prev
        prev = $0; pend = 1
      }
      END { if (pend) print prev }
    ' "$path" >"$TMP" || fail "could not rewrite $f"
  fi
  if [ "$REMOVE" = 0 ]; then
    if [ -s "$TMP" ]; then printf '\n' >>"$TMP"; fi
    render_block >>"$TMP"
  fi

  if [ -f "$path" ] && cmp -s "$TMP" "$path"; then
    rm -f "$TMP"; TMP=""
    FILES="${FILES:+$FILES,}$f"
    continue
  fi
  if [ -f "$path" ]; then
    mkdir -p "$BACKUP_DIR"
    if cp -p "$path" "$BACKUP_DIR/$f-$TS"; then BACKUP="$BACKUP_DIR/$f-$TS"; fi
  fi
  mv "$TMP" "$path" || fail "could not replace $f"
  TMP=""
  FILES="${FILES:+$FILES,}$f"
  if is_tracked "$f"; then TRACKED=yes; fi
  if [ "$REMOVE" = 1 ]; then REMOVED=1
  elif [ "$had_block" = yes ]; then UPDATED=1
  else WROTE=1
  fi
done

if [ "$WROTE" = 1 ]; then STATE=written
elif [ "$UPDATED" = 1 ]; then STATE=updated
elif [ "$REMOVED" = 1 ]; then STATE=removed
else STATE=unchanged
fi

REPORTED=1
report "$STATE"
