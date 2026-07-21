#!/bin/sh
# handoff-pull.sh [workspace] [flags] — bring handed-off work BACK from a
# Tireless workspace into the LOCAL repo (run from inside the project). The
# reverse of handoff-sync: one prompt-gated call fetches the workspace
# branch, fast-forwards local, carries the remote uncommitted diff and
# untracked files, and reports anything it could not safely bring.
#
#   --check              read-only probe: is the workspace ahead? Reports and
#                        exits without touching the local working tree (it
#                        does fetch into the temp ref refs/tireless/handback
#                        so ahead/behind counts are exact).
#   --target-dir DIR     remote project dir (default: the recorded handoff
#                        for this repo, else /home/dev/<ws>/<repo>)
#   --branch NAME        branch to pull (default: recorded, else current)
#   --session NAME       tmux session to probe for a running agent
#                        (default tireless-continue)
#   --even-if-running    pull although the workspace agent session is alive
#   --forget             delete this repo's pending-handoff record and exit
#                        (nothing is pulled; use when the workspace work was
#                        abandoned or the workspace no longer exists)
#
# Safety rules baked in: local commits are never rewritten (fast-forward
# only — divergence aborts with the merge left to you), the remote dirty
# diff is applied only when it applies cleanly (otherwise it is SAVED to
# ~/.timeless/handoffs/back/ and reported), untracked files never overwrite
# existing local paths (conflicts are listed, not clobbered), and gitignored
# remote files (env/secrets) never travel back implicitly.
#
# Output is KEY=val; the FIRST line is PULL=ok|none|abort|fail (--check:
# CHECK=ok|none|fail). PULL=ok still requires reading DIRTY_SAVED /
# UNTRACKED_SKIPPED / REMOTE_STASHES — "ok" means the safe subset landed,
# not that the workspace is empty-handed.
set -eu

. "$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/alias.sh"

TS="$(date -u +%Y%m%dT%H%M%SZ)"

WS=""
TARGET_DIR=""
BRANCH=""
SESSION=tireless-continue
CHECK=0
FORGET=0
EVEN_IF_RUNNING=0

usage() {
  echo "usage: handoff-pull.sh [workspace] [--check] [--target-dir DIR] [--branch NAME] [--session NAME] [--even-if-running] [--forget]" >&2
  exit 2
}

MODE_WORD=PULL
fail() {
  echo "$MODE_WORD=fail"
  echo "DETAIL=$1"
  exit 1
}

abort() {
  echo "$MODE_WORD=abort"
  echo "REASON=$1"
  if [ $# -gt 1 ]; then echo "NEXT=$2"; fi
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=1; MODE_WORD=CHECK ;;
    --forget) FORGET=1 ;;
    --even-if-running) EVEN_IF_RUNNING=1 ;;
    --target-dir) [ $# -ge 2 ] || usage; TARGET_DIR="$2"; shift ;;
    --branch) [ $# -ge 2 ] || usage; BRANCH="$2"; shift ;;
    --session) [ $# -ge 2 ] || usage; SESSION="$2"; shift ;;
    -*) usage ;;
    *) [ -z "$WS" ] || usage; WS="$1" ;;
  esac
  shift
done

# Same interpolation-safety rule as handoff-sync: constrain to a safe charset
# instead of escaping heroics. WS may be a bare name or a full ssh alias.
if [ -n "$WS" ]; then
  case "$WS" in -*|*[!a-zA-Z0-9.-]*) fail "workspace name has unsupported characters" ;; esac
fi
case "$SESSION" in ''|*[!a-zA-Z0-9_-]*) fail "session name has unsupported characters" ;; esac

# ---- local repo + handoff record -------------------------------------------
[ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" = true ] \
  || abort "not_a_repo" "run from inside the project that was handed off"
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
REC_DIR="$HOME/.timeless/handoffs/out"
ROOT_ID="$(printf '%s' "$ROOT" | cksum | awk '{print $1}')"

rec_get() { sed -n "s/^$2=//p" "$1" | head -1; }

REC_FILE=""
if [ -d "$REC_DIR" ]; then
  for f in "$REC_DIR"/*"--$ROOT_ID.rec"; do
    [ -f "$f" ] || continue
    if [ -n "$WS" ]; then
      [ "$(rec_get "$f" WS)" = "${WS%%.*}" ] || continue
    fi
    if [ -n "$REC_FILE" ]; then
      abort "ambiguous_record" "several workspaces have pending handoffs for this repo — name one: handoff-pull.sh <workspace>"
    fi
    REC_FILE="$f"
  done
fi

if [ "$FORGET" = 1 ]; then
  [ -n "$REC_FILE" ] || abort "no_record" "nothing recorded for this repo — nothing to forget"
  rm -f "$REC_FILE"
  echo "$MODE_WORD=ok"
  echo "FORGOTTEN=$(basename "$REC_FILE")"
  exit 0
fi

REC_ALIAS=""
if [ -n "$REC_FILE" ]; then
  # A recorded full alias beats a bare name — it skips suffix probing and
  # matches exactly what the sync used.
  REC_ALIAS="$(rec_get "$REC_FILE" ALIAS)"
  if [ -z "$WS" ]; then WS="${REC_ALIAS:-$(rec_get "$REC_FILE" WS)}"; fi
  [ -n "$TARGET_DIR" ] || TARGET_DIR="$(rec_get "$REC_FILE" TARGET_DIR)"
  [ -n "$BRANCH" ] || BRANCH="$(rec_get "$REC_FILE" BRANCH)"
fi
if [ -z "$WS" ]; then
  if [ "$CHECK" = 1 ]; then
    echo "CHECK=none"
    echo "DETAIL=no pending-handoff record for this repo and no workspace named"
    exit 0
  fi
  abort "no_record" "no pending-handoff record for this repo — name the workspace: handoff-pull.sh <workspace> [--target-dir DIR]"
fi
case "$WS" in -*|*[!a-zA-Z0-9.-]*) fail "workspace name has unsupported characters" ;; esac
[ -n "$TARGET_DIR" ] || TARGET_DIR="/home/dev/${WS%%.*}/$(basename "$ROOT")"
case "$TARGET_DIR" in /*) ;; *) fail "target dir must be absolute" ;; esac
case "$TARGET_DIR" in *[!a-zA-Z0-9/._-]*) fail "target dir has unsupported characters" ;; esac

if [ -z "$BRANCH" ]; then
  BRANCH="$(git symbolic-ref --short -q HEAD || true)"
  [ -n "$BRANCH" ] || abort "detached_head" "pass --branch <name> (the branch that was handed off)"
fi
case "$BRANCH" in *[!a-zA-Z0-9/._-]*) fail "branch name has unsupported characters" ;; esac

LOCAL_SHA="$(git rev-parse -q --verify HEAD 2>/dev/null || echo none)"

rsh() {
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" "$@"
}

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tireless-handback.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

# ---- remote facts (one round trip) -----------------------------------------
# Try the recorded alias first (exact match for what sync used), then the
# given/bare name through the regional-suffix resolver.
HOST=""
if [ -n "$REC_ALIAS" ]; then
  if ssh -o BatchMode=yes -o ConnectTimeout=10 "$REC_ALIAS" 'echo TIRELESS_OK' 2>/dev/null | grep -q TIRELESS_OK; then
    HOST="$REC_ALIAS"
  fi
fi
if [ -z "$HOST" ]; then
  HOST="$(tireless_resolve_alias "$WS")" \
    || fail "workspace unreachable over ssh — run the fix skill (workspace gone for good? handoff-pull.sh --forget clears the record)"
fi
rsh 'echo TIRELESS_OK' 2>/dev/null | grep -q TIRELESS_OK \
  || fail "workspace unreachable over ssh — run the fix skill (workspace gone for good? handoff-pull.sh --forget clears the record)"

facts="$(rsh "if [ ! -d '$TARGET_DIR' ]; then echo RD=missing; \
elif [ ! -d '$TARGET_DIR/.git' ]; then echo RD=not_repo; \
else cd '$TARGET_DIR'; echo RD=repo; \
  echo RSHA=\$(git rev-parse -q --verify 'refs/heads/$BRANCH' 2>/dev/null || echo none); \
  echo RDIRTY=\$(git status --porcelain | grep -c '^[^?]'); \
  echo RUNTRACKED=\$(git status --porcelain | grep -c '^??'); \
  echo RSTASH=\$(git stash list | grep -c .); \
  git for-each-ref --format='RBRANCH=%(objectname) %(refname:short)' refs/heads; \
fi; \
[ -s \"\$HOME/.timeless/handoffs/return.md\" ] && echo RRETURN=yes || echo RRETURN=no; \
tmux has-session -t '=$SESSION' 2>/dev/null && echo RSESSION=running || echo RSESSION=none")" \
  || fail "could not inspect $TARGET_DIR on the workspace"

fact() { printf '%s\n' "$facts" | sed -n "s/^$1=//p" | head -1; }
RD="$(fact RD)"
RSESSION="$(fact RSESSION)"

case "$RD" in
  missing) abort "remote_missing" "$TARGET_DIR does not exist on the workspace — wrong --target-dir, or the handoff never synced" ;;
  not_repo) abort "remote_not_repo" "$TARGET_DIR is not a git repo (tar-mode handoff?) — there is no git bring-back; copy what you need over ssh, or have the workspace agent git init + commit there first" ;;
  repo) ;;
  *) fail "could not inspect $TARGET_DIR on the workspace" ;;
esac

RSHA="$(fact RSHA)"
RDIRTY="$(fact RDIRTY)"
RUNTRACKED="$(fact RUNTRACKED)"
RSTASH="$(fact RSTASH)"
RRETURN="$(fact RRETURN)"
[ "$RSHA" != none ] \
  || abort "branch_missing_remote" "workspace repo has no branch '$BRANCH' — pass --branch with the branch the handoff used"

# Workspace branches (other than the handoff branch) whose tip commit local
# does not have — new work an agent parked on a side branch would otherwise
# be invisible to the whole hand-back.
NEW_BRANCHES=""
while IFS=' ' read -r bsha bname; do
  [ -n "$bname" ] || continue
  [ "$bname" = "$BRANCH" ] && continue
  if ! git cat-file -e "$bsha^{commit}" 2>/dev/null; then
    NEW_BRANCHES="${NEW_BRANCHES:+$NEW_BRANCHES:}$bname"
  fi
done <<EOF
$(printf '%s\n' "$facts" | sed -n 's/^RBRANCH=//p')
EOF

# ---- relation ---------------------------------------------------------------
REMOTE_AHEAD=0
LOCAL_AHEAD=0
RELATION=same
if [ "$RSHA" != "$LOCAL_SHA" ]; then
  GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=10" git fetch -q "ssh://$HOST$TARGET_DIR" "+refs/heads/$BRANCH:refs/tireless/handback" \
    || fail "could not fetch the workspace branch"
  REMOTE_AHEAD="$(git rev-list --count "${LOCAL_SHA}..refs/tireless/handback" 2>/dev/null || echo 0)"
  LOCAL_AHEAD="$(git rev-list --count "refs/tireless/handback..${LOCAL_SHA}" 2>/dev/null || echo 0)"
  if [ "$REMOTE_AHEAD" -gt 0 ] && [ "$LOCAL_AHEAD" -gt 0 ]; then RELATION=diverged
  elif [ "$REMOTE_AHEAD" -gt 0 ]; then RELATION=remote_ahead
  else RELATION=local_ahead
  fi
fi

# ---- check mode: report and stop -------------------------------------------
if [ "$CHECK" = 1 ]; then
  PULL_NEEDED=no
  if [ "$RELATION" = remote_ahead ] || [ "$RELATION" = diverged ] \
    || [ "$RDIRTY" -gt 0 ] || [ "$RUNTRACKED" -gt 0 ] || [ "$RSTASH" -gt 0 ] \
    || [ -n "$NEW_BRANCHES" ]; then
    PULL_NEEDED=yes
  fi
  echo "CHECK=ok"
  echo "WS=$WS"
  echo "TARGET_DIR=$TARGET_DIR"
  echo "BRANCH=$BRANCH"
  echo "RELATION=$RELATION"
  echo "REMOTE_AHEAD=$REMOTE_AHEAD"
  echo "LOCAL_AHEAD=$LOCAL_AHEAD"
  echo "REMOTE_DIRTY=$RDIRTY"
  echo "REMOTE_UNTRACKED=$RUNTRACKED"
  echo "REMOTE_STASHES=$RSTASH"
  echo "REMOTE_NEW_BRANCHES=${NEW_BRANCHES:-none}"
  echo "RETURN_BRIEF_REMOTE=$RRETURN"
  echo "SESSION=$RSESSION"
  echo "PULL_NEEDED=$PULL_NEEDED"
  if [ -n "$REC_FILE" ] && [ "$PULL_NEEDED" = no ] && [ "$RELATION" != local_ahead ]; then
    # Parity confirmed — stop the session-start nag until the next handoff.
    sed 's/^RESOLVED=.*/RESOLVED=yes/' "$REC_FILE" >"$REC_FILE.tmp" && mv "$REC_FILE.tmp" "$REC_FILE"
  fi
  exit 0
fi

# ---- pull mode --------------------------------------------------------------
if [ "$RSESSION" = running ] && [ "$EVEN_IF_RUNNING" != 1 ]; then
  abort "session_running" "the workspace agent session '$SESSION' is still running — let it finish or stop it (tireless-handoff-launch $WS $TARGET_DIR --stop), or re-run with --even-if-running to pull a snapshot mid-flight"
fi

if [ "$RELATION" = diverged ]; then
  abort "diverged" "local and workspace both have new commits — merge deliberately: git merge refs/tireless/handback (the workspace commits are already fetched), then re-run to collect the uncommitted remainder"
fi

PULLED_COMMITS=0
if [ "$RELATION" = remote_ahead ]; then
  CUR_BRANCH="$(git symbolic-ref --short -q HEAD || true)"
  [ "$CUR_BRANCH" = "$BRANCH" ] \
    || abort "branch_mismatch" "local checkout is on '${CUR_BRANCH:-<detached>}' but the handoff branch is '$BRANCH' — git checkout $BRANCH first, then re-run"
  git merge --ff-only -q refs/tireless/handback \
    || abort "ff_blocked" "fast-forward failed (local uncommitted changes overlap the workspace commits) — commit or stash local changes, then re-run"
  PULLED_COMMITS="$REMOTE_AHEAD"
  LOCAL_SHA="$(git rev-parse HEAD)"
fi

# ---- remote uncommitted diff ------------------------------------------------
DIRTY_APPLIED=0
DIRTY_ALREADY=no
DIRTY_SAVED=none
if [ "$RDIRTY" -gt 0 ]; then
  rsh "cd '$TARGET_DIR' && git diff --binary HEAD" >"$TMP_DIR/back.patch" \
    || fail "could not read the workspace's uncommitted changes"
  if [ -s "$TMP_DIR/back.patch" ]; then
    # The patch's base is the remote HEAD; apply only when local HEAD equals
    # it (true after a fast-forward or at parity) AND it applies cleanly.
    if [ "$(git rev-parse HEAD)" = "$RSHA" ] \
      && git apply --binary --check "$TMP_DIR/back.patch" 2>/dev/null; then
      git apply --binary --whitespace=nowarn "$TMP_DIR/back.patch" \
        || fail "could not apply the workspace's uncommitted changes"
      DIRTY_APPLIED="$RDIRTY"
    elif git apply --binary --reverse --check "$TMP_DIR/back.patch" 2>/dev/null; then
      # Reverse-applies cleanly = the local tree already contains exactly
      # these changes (a previous pull brought them) — nothing to do.
      DIRTY_ALREADY=yes
    else
      # Different base (local_ahead) or overlapping local edits: never guess —
      # park the patch where briefs live and hand the decision back.
      mkdir -p "$HOME/.timeless/handoffs/back"
      DIRTY_SAVED="$HOME/.timeless/handoffs/back/$WS-$TS.patch"
      cp "$TMP_DIR/back.patch" "$DIRTY_SAVED"
    fi
  fi
fi

# ---- remote untracked files -------------------------------------------------
# Three buckets: absent locally -> bring over; present with IDENTICAL content
# (compared by git blob hash) -> already there, stay quiet (repeat pulls must
# not re-alarm); present but DIFFERENT -> never clobber, list it and let the
# agent/user decide.
UNTRACKED_IN=0
UNTRACKED_SAME=0
UNTRACKED_SKIPPED=0
SKIPPED_LIST=none
rsh "cd '$TARGET_DIR' && git ls-files --others --exclude-standard" >"$TMP_DIR/rlist.txt" \
  || fail "could not list the workspace's untracked files"
if [ -s "$TMP_DIR/rlist.txt" ]; then
  # Hashes arrive in ls-files order, so line N of each file pairs up.
  rsh "cd '$TARGET_DIR' && git ls-files -z --others --exclude-standard | xargs -0 git hash-object --" >"$TMP_DIR/rhashes.txt" \
    || fail "could not hash the workspace's untracked files"
  paste "$TMP_DIR/rhashes.txt" "$TMP_DIR/rlist.txt" >"$TMP_DIR/rpaired.txt"
  : >"$TMP_DIR/include.z"
  : >"$TMP_DIR/include.txt"
  : >"$TMP_DIR/skipped.txt"
  TAB="$(printf '\t')"
  while IFS="$TAB" read -r h f; do
    [ -n "$f" ] || continue
    if [ ! -e "$f" ]; then
      printf '%s\0' "$f" >>"$TMP_DIR/include.z"
      printf '%s\n' "$f" >>"$TMP_DIR/include.txt"
      UNTRACKED_IN=$((UNTRACKED_IN + 1))
    elif [ "$(git hash-object -- "$f" 2>/dev/null)" = "$h" ]; then
      UNTRACKED_SAME=$((UNTRACKED_SAME + 1))
    else
      printf '%s\n' "$f" >>"$TMP_DIR/skipped.txt"
      UNTRACKED_SKIPPED=$((UNTRACKED_SKIPPED + 1))
    fi
  done <"$TMP_DIR/rpaired.txt"
  if [ "$UNTRACKED_IN" -gt 0 ]; then
    rsh "cd '$TARGET_DIR' && tar -czf - --null -T -" <"$TMP_DIR/include.z" >"$TMP_DIR/untracked.tgz" \
      || fail "could not archive the workspace's untracked files"
    # The archive BYTES are remote-produced, so it never unpacks into the
    # repo directly: extract into a scratch dir, then copy across only the
    # listed paths — each must be relative, carry no '..' component, and
    # resolve (symlinks included) inside the scratch dir. A tampered remote
    # tar (absolute paths, dot-dot segments, symlink-chained entries) then
    # cannot write outside the repo.
    mkdir "$TMP_DIR/x"
    tar -xzf "$TMP_DIR/untracked.tgz" -C "$TMP_DIR/x" \
      || fail "could not extract the workspace's untracked files locally"
    xphys="$(CDPATH='' cd -P "$TMP_DIR/x" && pwd -P)"
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      case "$f" in
        /*|..|../*|*/..|*/../*) fail "workspace archive carries an unsafe path: $f" ;;
      esac
      src="$TMP_DIR/x/$f"
      [ -L "$src" ] || [ -f "$src" ] \
        || fail "workspace archive is missing a listed file: $f"
      resolved="$(CDPATH='' cd -P "$(dirname "$src")" 2>/dev/null && pwd -P)" \
        || fail "workspace archive carries an unresolvable path: $f"
      case "$resolved" in
        "$xphys"|"$xphys/"*) ;;
        *) fail "workspace archive escapes its tree through a symlink: $f" ;;
      esac
      mkdir -p "$(dirname "$ROOT/$f")" \
        || fail "could not create the directory for an untracked file: $f"
      cp -RPp "$src" "$ROOT/$f" \
        || fail "could not restore an untracked file: $f"
    done <"$TMP_DIR/include.txt"
  fi
  if [ "$UNTRACKED_SKIPPED" -gt 0 ]; then
    mkdir -p "$HOME/.timeless/handoffs/back"
    SKIPPED_LIST="$HOME/.timeless/handoffs/back/$WS-$TS-skipped.txt"
    cp "$TMP_DIR/skipped.txt" "$SKIPPED_LIST"
  fi
fi

# ---- return brief -----------------------------------------------------------
# The launch kickoff asks the workspace agent to keep ~/.timeless/handoffs/
# return.md — its session context riding home is the other half of a handoff.
RETURN_BRIEF=none
if [ "$RRETURN" = yes ]; then
  mkdir -p "$HOME/.timeless/handoffs/back"
  if rsh 'cat "$HOME/.timeless/handoffs/return.md"' >"$HOME/.timeless/handoffs/back/$WS-$TS-return.md" 2>/dev/null; then
    RETURN_BRIEF="$HOME/.timeless/handoffs/back/$WS-$TS-return.md"
  fi
fi

# ---- record + verdict -------------------------------------------------------
RESOLVED=no
if [ "$DIRTY_SAVED" = none ] && [ "$UNTRACKED_SKIPPED" = 0 ] && [ "$RSTASH" = 0 ] \
  && [ -z "$NEW_BRANCHES" ] \
  && { [ "$RELATION" = same ] || [ "$RELATION" = remote_ahead ]; }; then
  RESOLVED=yes
fi
if [ -n "$REC_FILE" ]; then
  {
    echo "SCHEMA=tireless-handback/v1"
    echo "WS=${WS%%.*}"
    echo "ALIAS=$HOST"
    echo "TARGET_DIR=$TARGET_DIR"
    echo "BRANCH=$BRANCH"
    echo "HEAD_SHA=$(git rev-parse -q --verify HEAD 2>/dev/null || echo none)"
    echo "MODE=git"
    echo "LOCAL_ROOT=$ROOT"
    echo "SYNCED_AT=$(rec_get "$REC_FILE" SYNCED_AT)"
    echo "LAST_PULL=$TS"
    echo "RESOLVED=$RESOLVED"
  } >"$REC_FILE.tmp" && mv "$REC_FILE.tmp" "$REC_FILE"
fi

if [ "$RELATION" = local_ahead ] && [ "$PULLED_COMMITS" = 0 ] && [ "$DIRTY_APPLIED" = 0 ] \
  && [ "$DIRTY_SAVED" = none ] && [ "$UNTRACKED_IN" = 0 ] && [ "$UNTRACKED_SKIPPED" = 0 ]; then
  echo "PULL=none"
  echo "RELATION=local_ahead"
  echo "RETURN_BRIEF=$RETURN_BRIEF"
  echo "DETAIL=the workspace has nothing local lacks — local is $LOCAL_AHEAD commit(s) ahead; run tireless-handoff-sync to update the workspace instead"
  exit 0
fi
if [ "$RELATION" = same ] && [ "$RDIRTY" = 0 ] && [ "$UNTRACKED_IN" = 0 ] \
  && [ "$UNTRACKED_SKIPPED" = 0 ] && [ "$RSTASH" = 0 ]; then
  echo "PULL=none"
  echo "RELATION=same"
  echo "RETURN_BRIEF=$RETURN_BRIEF"
  echo "DETAIL=workspace and local are identical — nothing to bring back"
  exit 0
fi

echo "PULL=ok"
echo "BRANCH=$BRANCH"
echo "RELATION=$RELATION"
echo "PULLED_COMMITS=$PULLED_COMMITS"
echo "HEAD_SHA=$(git rev-parse -q --verify HEAD 2>/dev/null || echo none)"
echo "DIRTY_APPLIED=$DIRTY_APPLIED"
echo "DIRTY_ALREADY=$DIRTY_ALREADY"
echo "DIRTY_SAVED=$DIRTY_SAVED"
echo "UNTRACKED_IN=$UNTRACKED_IN"
echo "UNTRACKED_SAME=$UNTRACKED_SAME"
echo "UNTRACKED_SKIPPED=$UNTRACKED_SKIPPED"
echo "SKIPPED_LIST=$SKIPPED_LIST"
echo "REMOTE_STASHES=$RSTASH"
echo "REMOTE_NEW_BRANCHES=${NEW_BRANCHES:-none}"
echo "RETURN_BRIEF=$RETURN_BRIEF"
echo "RESOLVED=$RESOLVED"
