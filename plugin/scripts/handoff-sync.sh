#!/bin/sh
# handoff-sync.sh <workspace> [flags] — one-shot code+context sync from the
# LOCAL repo (cwd) to a Tireless workspace, over the existing ssh alias. This
# is the single mutating command behind the continue skill: everything a
# handoff needs crosses in one prompt-gated call, so the agent never
# improvises raw git plumbing.
#
#   --target-dir DIR     remote project dir (default /home/dev/<ws>/<repo>)
#   --branch NAME        branch to materialize remotely (default: current
#                        branch; REQUIRED when HEAD is detached)
#   --brief FILE         handoff brief -> ~/.timeless/handoffs/ + latest.md
#   --include PATH       repo-relative gitignored file to carry anyway (env
#                        files etc.; repeatable; lands mode 0600)
#   --force-overwrite    proceed when the remote branch has commits local
#                        HEAD lacks (a remote backup branch is created first)
#   --tar-mode           no-history fallback: ship the tree without git.
#                        Inside a work tree this still respects .gitignore
#                        (tracked + untracked-not-ignored + --include only);
#                        outside any repo it ships the WHOLE directory,
#                        gitignored secrets included — disclose that.
#
# What travels (git mode): commits reachable from HEAD (pushed to the temp
# ref refs/tireless/handoff, then `checkout -B <branch>` remotely — never
# touches a checked-out branch ref, so receive.denyCurrentBranch can't fire),
# the uncommitted diff (git apply --binary, arrives unstaged), untracked
# not-ignored files (tar), --include files, and the brief. Submodule content
# and LFS blobs do NOT travel — the skill warns about those beforehand.
#
# Output is KEY=val; the FIRST line is SYNC=ok|abort|fail.
#   SYNC=abort REASON=... NEXT=...   expected condition with a next step
#   SYNC=fail  DETAIL=...            unexpected breakage — switch to fix skill
set -eu

. "$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/alias.sh"

TS="$(date -u +%Y%m%dT%H%M%SZ)"

WS=""
TARGET_DIR=""
BRANCH=""
BRIEF_FILE=""
INCLUDES=""
FORCE=0
TAR_MODE=0
REMOTE_STASHED=no

usage() {
  echo "usage: handoff-sync.sh <workspace> [--target-dir DIR] [--branch NAME] [--brief FILE] [--include PATH]... [--force-overwrite] [--tar-mode]" >&2
  exit 2
}

fail() {
  echo "SYNC=fail"
  echo "DETAIL=$1"
  # A stash parked before the failure must never go undisclosed: a retry
  # would stash again and the first park would silently age out of sight.
  if [ "$REMOTE_STASHED" = yes ]; then echo "REMOTE_STASHED=yes"; fi
  exit 1
}

abort() {
  echo "SYNC=abort"
  echo "REASON=$1"
  if [ $# -gt 1 ]; then echo "NEXT=$2"; fi
  if [ "$REMOTE_STASHED" = yes ]; then echo "REMOTE_STASHED=yes"; fi
  exit 1
}

# Back up remote copies of --include files before overwriting: they are
# gitignored, so neither the stash park nor the backup branch ever protects
# them — a remote agent's .env edits would be silently destroyed otherwise.
INCLUDE_BACKUP=none
backup_includes() {
  [ -n "$INCLUDES" ] || return 0
  OLDIFS=$IFS; IFS='
'
  for inc in $INCLUDES; do
    if rsh "[ -f '$TARGET_DIR/$inc' ] && mkdir -p \"\$HOME/.timeless/handoffs/pre-$TS/\$(dirname '$inc')\" && cp -p '$TARGET_DIR/$inc' \"\$HOME/.timeless/handoffs/pre-$TS/$inc\"" 2>/dev/null; then
      # shellcheck disable=SC2088 -- a REMOTE path shown to the user, ~ is right
      INCLUDE_BACKUP="~/.timeless/handoffs/pre-$TS/"
    fi
  done
  IFS=$OLDIFS
}

check_branch() {
  case "$1" in *[!a-zA-Z0-9/._-]*) fail "branch name has unsupported characters" ;; esac
}

check_target_dir() {
  case "$1" in /*) ;; *) fail "target dir must be absolute" ;; esac
  case "$1" in *[!a-zA-Z0-9/._-]*) fail "target dir has unsupported characters" ;; esac
}

[ $# -ge 1 ] || usage
WS="$1"; shift
while [ $# -gt 0 ]; do
  case "$1" in
    --target-dir) [ $# -ge 2 ] || usage; TARGET_DIR="$2"; shift ;;
    --branch) [ $# -ge 2 ] || usage; BRANCH="$2"; shift ;;
    --brief) [ $# -ge 2 ] || usage; BRIEF_FILE="$2"; shift ;;
    --include) [ $# -ge 2 ] || usage; INCLUDES="${INCLUDES:+$INCLUDES
}$2"; shift ;;
    --force-overwrite) FORCE=1 ;;
    --tar-mode) TAR_MODE=1 ;;
    *) usage ;;
  esac
  shift
done

# Values are interpolated into remote shell commands inside single quotes —
# constrain them to a safe charset instead of escaping heroics. BRANCH and
# TARGET_DIR are re-validated below after defaults are derived (git branch
# names can legally contain quote characters). WS may be a bare name or a
# full ssh alias (dots) — WS_NAME is the bare workspace name for paths.
case "$WS" in ''|-*|*[!a-zA-Z0-9.-]*) fail "workspace name has unsupported characters" ;; esac
WS_NAME="${WS%%.*}"

rsh() {
  # Options stay literal words — never a split $SSH_OPTS variable: rsh runs
  # inside IFS-modified loops (the --include chmod passes), where splitting
  # on spaces stops working and ssh would reject the mangled -o value. That
  # exact bug once shipped --include files as mode 644 instead of 600.
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" "$@"
}

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tireless-handoff.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

if [ -n "$BRIEF_FILE" ] && [ ! -f "$BRIEF_FILE" ]; then
  fail "brief file not found: $BRIEF_FILE"
fi

# ---- local repo facts ------------------------------------------------------
# --is-inside-work-tree prints "false" (exit 0) in bare repos / .git dirs, so
# test the OUTPUT — an exit-status test would crash later with no SYNC= line.
IN_WORK_TREE="$(git rev-parse --is-inside-work-tree 2>/dev/null || true)"
if [ "$TAR_MODE" = 0 ]; then
  [ "$IN_WORK_TREE" = true ] \
    || abort "not_a_repo" "re-run with --tar-mode from the project directory to ship it without git history"
  ROOT="$(git rev-parse --show-toplevel)"
  cd "$ROOT"
  REPO_NAME="$(basename "$ROOT")"
  git rev-parse -q --verify HEAD >/dev/null 2>&1 \
    || abort "unborn_head" "no commits yet — commit first or re-run with --tar-mode"
  HEAD_SHA="$(git rev-parse HEAD)"
  if [ -z "$BRANCH" ]; then
    BRANCH="$(git symbolic-ref --short -q HEAD || true)"
    [ -n "$BRANCH" ] || abort "detached_head" "pass --branch <name> (e.g. tireless/handoff-$TS)"
  fi
else
  if [ "$IN_WORK_TREE" = true ]; then
    ROOT="$(git rev-parse --show-toplevel)"
    cd "$ROOT"
    REPO_NAME="$(basename "$ROOT")"
  else
    REPO_NAME="$(basename "$PWD")"
  fi
  HEAD_SHA=none
  BRANCH="${BRANCH:-none}"
fi
check_branch "$BRANCH"
[ -n "$TARGET_DIR" ] || TARGET_DIR="/home/dev/$WS_NAME/$REPO_NAME"
check_target_dir "$TARGET_DIR"

# --include paths must exist and stay inside the same charset (they are
# quoted into remote chmod/tar commands).
if [ -n "$INCLUDES" ]; then
  OLDIFS=$IFS; IFS='
'
  for inc in $INCLUDES; do
    case "$inc" in
      /*|*..*) fail "--include must be a repo-relative path: $inc" ;;
      *[!a-zA-Z0-9/._-]*) fail "--include path has unsupported characters: $inc" ;;
    esac
    [ -f "$inc" ] || fail "--include file not found: $inc"
  done
  IFS=$OLDIFS
fi

# ---- reachability ----------------------------------------------------------
# Resolution doubles as the reachability gate: a bare name is probed against
# the regional suffixes the local ssh fragments define (legacy .tireless
# last); a full alias (dots) is probed as-is.
HOST="$(tireless_resolve_alias "$WS")" \
  || fail "workspace unreachable over ssh (no alias for '$WS' answers) — run the fix skill"
rsh 'echo TIRELESS_OK' 2>/dev/null | grep -q TIRELESS_OK \
  || fail "workspace unreachable over ssh — run the fix skill"

# ---- tar-mode: tree snapshot, no git ceremony ------------------------------
# Archive to a temp file FIRST: POSIX sh has no pipefail, so in a
# local|remote pipeline a local tar error (unreadable file, file changed
# while reading) would be masked by the remote side's exit 0.
if [ "$TAR_MODE" = 1 ]; then
  # Extraction is an additive overlay: it never deletes remote files, so a
  # pre-existing non-empty target silently diverges from the laptop (stale
  # files persist). Require an explicit opt-in for that.
  tar_state="$(rsh "if [ -e '$TARGET_DIR' ] && [ -n \"\$(ls -A '$TARGET_DIR' 2>/dev/null)\" ]; then echo nonempty; else echo empty; fi; echo TIRELESS_END" 2>/dev/null)" || true
  case "$tar_state" in
    *TIRELESS_END*) ;;
    *) fail "could not inspect $TARGET_DIR on the workspace" ;;
  esac
  if [ "$(printf '%s\n' "$tar_state" | sed -n 1p)" = nonempty ] && [ "$FORCE" != 1 ]; then
    abort "dir_exists" "$TARGET_DIR exists and is not empty — tar-mode overlays files without deleting remote ones (the trees can diverge). Pick a fresh --target-dir, or re-run with --force-overwrite to accept the overlay"
  fi
  if [ "$IN_WORK_TREE" = true ]; then
    # Respect ignore rules: tracked + untracked-not-ignored (+ --include).
    # Submodule paths are listed as directories, so their contents DO travel
    # here — that is tar-mode's job. Gitignored files travel only via the
    # confirm-gated --include flow. Filter out paths that no longer exist on
    # disk (an uncommitted `rm` keeps the file in --cached and would make
    # tar error out on a perfectly ordinary tree).
    git ls-files --cached --others --exclude-standard -z >"$TMP_DIR/tree0.z"
    : >"$TMP_DIR/tree.z"
    tr '\0' '\n' <"$TMP_DIR/tree0.z" | while IFS= read -r f; do
      [ -n "$f" ] && [ -e "$f" ] && printf '%s\0' "$f" >>"$TMP_DIR/tree.z"
    done
    if [ -n "$INCLUDES" ]; then
      OLDIFS=$IFS; IFS='
'
      for inc in $INCLUDES; do printf '%s\0' "$inc" >>"$TMP_DIR/tree.z"; done
      IFS=$OLDIFS
    fi
    tar -czf "$TMP_DIR/tree.tgz" --null -T "$TMP_DIR/tree.z" \
      || fail "could not archive the working tree"
  else
    tar -czf "$TMP_DIR/tree.tgz" --exclude .git . \
      || fail "could not archive the directory"
  fi
  backup_includes
  rsh "mkdir -p '$TARGET_DIR' && tar -xzf - -C '$TARGET_DIR'" <"$TMP_DIR/tree.tgz" \
    || fail "tar transfer failed"
  if [ -n "$INCLUDES" ]; then
    OLDIFS=$IFS; IFS='
'
    for inc in $INCLUDES; do
      rsh "chmod 600 '$TARGET_DIR/$inc'" || true
    done
    IFS=$OLDIFS
  fi
  SYNCED_MODE=tar
else
  # ---- ensure remote repo ----------------------------------------------------
  state="$(rsh "if [ -d '$TARGET_DIR/.git' ]; then echo repo; \
    elif [ -e '$TARGET_DIR' ] && [ -n \"\$(ls -A '$TARGET_DIR' 2>/dev/null)\" ]; then echo nonempty; \
    else echo absent; fi")" || fail "could not inspect $TARGET_DIR on the workspace"
  case "$state" in
    repo) ;;
    nonempty) abort "dir_not_repo" "$TARGET_DIR exists and is not a git repo — pass a different --target-dir or --tar-mode" ;;
    absent) rsh "git init -q '$TARGET_DIR'" || fail "git init on workspace failed" ;;
    *) fail "could not inspect $TARGET_DIR on the workspace" ;;
  esac

  # Repo-local identity so the continuing agent can commit/stash. Only when
  # nothing (local/global/system) is configured on the workspace.
  rsh "cd '$TARGET_DIR' && { git config user.email >/dev/null 2>&1 || { git config user.email 'dev@$HOST' && git config user.name 'Tireless Dev'; }; }" \
    || fail "could not check git identity on workspace"

  # ---- divergence guard ------------------------------------------------------
  # Sentinel-marked probe: an ssh failure must be SYNC=fail, never read as
  # "branch absent" — that misread once skipped the guard entirely and let
  # checkout -B strand remote-only commits. Also detect a detached remote
  # HEAD (agent mid-rebase): its commits are invisible to a refs/heads probe.
  BACKUP_BRANCH=none
  probe="$(rsh "git -C '$TARGET_DIR' rev-parse -q --verify 'refs/heads/$BRANCH' || echo TIRELESS_NONE; git -C '$TARGET_DIR' symbolic-ref -q HEAD >/dev/null && echo TIRELESS_ONBRANCH || echo TIRELESS_DETACHED; echo TIRELESS_END" 2>/dev/null)" || true
  case "$probe" in
    *TIRELESS_END*) ;;
    *) fail "could not probe the workspace branch state — run the fix skill" ;;
  esac
  remote_sha="$(printf '%s\n' "$probe" | sed -n 1p)"
  case "$remote_sha" in TIRELESS_NONE|TIRELESS_ONBRANCH|TIRELESS_DETACHED) remote_sha="" ;; esac
  if printf '%s' "$probe" | grep -q TIRELESS_DETACHED; then
    if [ "$FORCE" = 1 ]; then
      rsh "git -C '$TARGET_DIR' branch 'tireless/backup-$TS' HEAD" \
        || fail "could not back up the workspace's detached HEAD"
      BACKUP_BRANCH="tireless/backup-$TS"
    else
      abort "remote_detached" "the workspace repo is on a detached HEAD (agent mid-rebase?) — finish or abort that on the workspace first, or re-run with --force-overwrite (its HEAD gets a backup branch)"
    fi
  fi
  if [ -n "$remote_sha" ] && [ "$remote_sha" != "$HEAD_SHA" ]; then
    GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=10" git fetch -q "ssh://$HOST$TARGET_DIR" \
      "+refs/heads/$BRANCH:refs/tireless/remote-check" \
      || fail "could not fetch workspace branch for the divergence check"
    is_ancestor=0
    git merge-base --is-ancestor refs/tireless/remote-check HEAD || is_ancestor=$?
    git update-ref -d refs/tireless/remote-check 2>/dev/null || true
    if [ "$is_ancestor" != 0 ]; then
      if [ "$FORCE" = 1 ]; then
        if [ "$BACKUP_BRANCH" = none ]; then
          rsh "git -C '$TARGET_DIR' branch 'tireless/backup-$TS' 'refs/heads/$BRANCH'" \
            || fail "could not create remote backup branch"
          BACKUP_BRANCH="tireless/backup-$TS"
        fi
      else
        abort "remote_ahead" "workspace has commits local HEAD lacks — bring them back first: tireless-handoff-pull $WS  (or re-run with --force-overwrite to back up + overwrite)"
      fi
    fi
  fi

  # ---- park remote uncommitted changes ---------------------------------------
  # Same sentinel rule: a swallowed status probe must not read as "clean".
  status_probe="$(rsh "cd '$TARGET_DIR' && git status --porcelain | head -1; echo TIRELESS_END" 2>/dev/null)" || true
  case "$status_probe" in
    *TIRELESS_END*) ;;
    *) fail "could not probe the workspace tree state — run the fix skill" ;;
  esac
  if [ "$(printf '%s\n' "$status_probe" | sed -n 1p)" != TIRELESS_END ]; then
    rsh "cd '$TARGET_DIR' && git stash push -q -u -m 'tireless-continue $TS'" \
      || fail "could not stash uncommitted changes on the workspace"
    REMOTE_STASHED=yes
  fi

  # ---- push + materialize ----------------------------------------------------
  GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=10" git push -q "ssh://$HOST$TARGET_DIR" "+HEAD:refs/tireless/handoff" \
    || fail "git push to the workspace failed"
  rsh "cd '$TARGET_DIR' && git checkout -q -B '$BRANCH' refs/tireless/handoff" \
    || fail "checkout on the workspace failed"

  # ---- uncommitted overlay ---------------------------------------------------
  DIRTY_APPLIED=0
  git diff --binary HEAD >"$TMP_DIR/dirty.patch"
  if [ -s "$TMP_DIR/dirty.patch" ]; then
    rsh "cd '$TARGET_DIR' && git apply --binary --whitespace=nowarn" <"$TMP_DIR/dirty.patch" \
      || fail "could not apply uncommitted changes on the workspace"
    DIRTY_APPLIED="$(git diff --name-only HEAD | wc -l | tr -d ' ')"
  fi

  # ---- untracked files + --include -------------------------------------------
  git ls-files --others --exclude-standard -z >"$TMP_DIR/files.z"
  UNTRACKED_SENT="$(git ls-files --others --exclude-standard | wc -l | tr -d ' ')"
  if [ -n "$INCLUDES" ]; then
    OLDIFS=$IFS; IFS='
'
    for inc in $INCLUDES; do
      printf '%s\0' "$inc" >>"$TMP_DIR/files.z"
      UNTRACKED_SENT=$((UNTRACKED_SENT + 1))
    done
    IFS=$OLDIFS
  fi
  if [ -s "$TMP_DIR/files.z" ]; then
    tar -czf "$TMP_DIR/untracked.tgz" --null -T "$TMP_DIR/files.z" \
      || fail "could not archive untracked files"
    backup_includes
    rsh "cd '$TARGET_DIR' && tar -xzf -" <"$TMP_DIR/untracked.tgz" \
      || fail "could not copy untracked files to the workspace"
    if [ -n "$INCLUDES" ]; then
      OLDIFS=$IFS; IFS='
'
      for inc in $INCLUDES; do
        rsh "chmod 600 '$TARGET_DIR/$inc'" || true
      done
      IFS=$OLDIFS
    fi
  fi
  SYNCED_MODE=git
fi

# ---- brief + discovery sentinel ---------------------------------------------
BRIEF=none
if [ -n "$BRIEF_FILE" ]; then
  BRIEF_NAME="$WS-$TS.md"
  # Ship a working copy: when remote changes were stashed, the continuing
  # agent must learn about them from the brief itself.
  cp "$BRIEF_FILE" "$TMP_DIR/brief.md"
  if [ "$REMOTE_STASHED" = yes ]; then
    printf '\n## Parked remote changes\nThe workspace tree had uncommitted changes before this handoff; they were stashed as "tireless-continue %s". Run `git stash list` and decide with the user whether to pop or drop them.\n' "$TS" >>"$TMP_DIR/brief.md"
  fi
  rsh 'mkdir -p "$HOME/.timeless/handoffs"' || fail "could not create handoffs dir"
  scp -o BatchMode=yes -o ConnectTimeout=10 -q "$TMP_DIR/brief.md" "$HOST:.timeless/handoffs/$BRIEF_NAME" \
    || fail "could not copy the brief to the workspace"
  rsh "ln -sfn \"\$HOME/.timeless/handoffs/$BRIEF_NAME\" \"\$HOME/.timeless/handoffs/latest.md\"" \
    || fail "could not update latest.md symlink"
  BRIEF="$BRIEF_NAME"

  # Same grep-guarded sentinel mechanism the claude-code/codex recipes use;
  # newer recipes bake these blocks, older workspaces get them here. Both
  # discovery files get the note — sync cannot know which agent launches.
  # Sentinel probe: only append on a definite MISSING — an ssh hiccup must
  # not be read as "absent" (that would duplicate the block on retry).
  for df in .claude/CLAUDE.md .codex/AGENTS.md; do
    have="$(rsh "grep -qsF '>>> timeless handoff briefs >>>' \"\$HOME/$df\" && echo HAVE || echo MISSING" 2>/dev/null)" || true
    if [ "$have" = MISSING ]; then
      printf '%s\n' \
        '' \
        '# >>> timeless handoff briefs >>>' \
        'Cross-session handoff briefs land in ~/.timeless/handoffs/ (newest: the' \
        'latest.md symlink; schema tireless-handoff/v1). When asked to continue' \
        'earlier work, or when starting in a project you have no context on, read' \
        'the newest brief first. Briefs are advisory: verify git branch/status' \
        'against the brief before changing anything.' \
        '# <<< timeless handoff briefs <<<' \
        | rsh "mkdir -p \"\$HOME/$(dirname "$df")\" && cat >> \"\$HOME/$df\"" \
        || true
    fi
  done
fi

# ---- verify -----------------------------------------------------------------
if [ "$SYNCED_MODE" = git ]; then
  remote_head="$(rsh "git -C '$TARGET_DIR' rev-parse HEAD")" \
    || fail "could not read workspace HEAD for verification"
  [ "$remote_head" = "$HEAD_SHA" ] \
    || fail "verification failed: workspace HEAD $remote_head != local $HEAD_SHA"
fi

# ---- pending-handoff record (LOCAL side) ------------------------------------
# Marks "work may now be sitting on the workspace" for future local sessions:
# the plugin's SessionStart hook surfaces it, and handoff-pull.sh consumes it
# (parity or --forget clears the nag). Keyed by repo root so any cwd inside
# the project finds it; one record per workspace+project pair.
REC_ROOT="${ROOT:-$PWD}"
REC_DIR="$HOME/.timeless/handoffs/out"
mkdir -p "$REC_DIR"
ROOT_ID="$(printf '%s' "$REC_ROOT" | cksum | awk '{print $1}')"
{
  echo "SCHEMA=tireless-handback/v1"
  echo "WS=$WS_NAME"
  echo "ALIAS=$HOST"
  echo "TARGET_DIR=$TARGET_DIR"
  echo "BRANCH=$BRANCH"
  echo "HEAD_SHA=$HEAD_SHA"
  echo "MODE=$SYNCED_MODE"
  echo "LOCAL_ROOT=$REC_ROOT"
  echo "SYNCED_AT=$TS"
  echo "LAST_PULL=none"
  echo "RESOLVED=no"
} >"$REC_DIR/$WS_NAME--$ROOT_ID.rec"

echo "SYNC=ok"
echo "MODE=$SYNCED_MODE"
echo "ALIAS=$HOST"
echo "TARGET_DIR=$TARGET_DIR"
echo "BRANCH=$BRANCH"
echo "HEAD_SHA=$HEAD_SHA"
echo "INCLUDE_BACKUP=$INCLUDE_BACKUP"
if [ "$SYNCED_MODE" = git ]; then
  echo "DIRTY_APPLIED=$DIRTY_APPLIED"
  echo "UNTRACKED_SENT=$UNTRACKED_SENT"
  echo "REMOTE_STASHED=$REMOTE_STASHED"
  echo "BACKUP_BRANCH=$BACKUP_BRANCH"
fi
echo "BRIEF=$BRIEF"
