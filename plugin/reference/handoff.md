# Session handoff to a workspace — design notes + brief template

How "continue this on my workspace" works, why it works that way, and the
exact brief format. The continue skill is the walkthrough; this is the
background an agent (or maintainer) needs when something is off-script.

## How code travels: direct git-over-ssh, no GitHub

`tireless-handoff-sync` pushes straight to the workspace through the
workspace's ssh alias (the resolver in `scripts/alias.sh` turns a bare
name into the regional form, e.g. `myws.eu-central.tireless`):

1. `git push ssh://<alias><target-dir> +HEAD:refs/tireless/handoff` —
   a namespaced temp ref, so the remote's checked-out branch ref is never
   touched and `receive.denyCurrentBranch` can never fire. The `+` force is
   safe because divergence was checked explicitly first (fetch remote head,
   `merge-base --is-ancestor`).
2. Remote `git checkout -B <branch> refs/tireless/handoff` materializes the
   branch at exactly the local HEAD.
3. The uncommitted diff rides separately (`git diff --binary | git apply`) —
   it applies cleanly by construction because the remote tree now equals the
   diff's base. It arrives unstaged; the staged/unstaged split is not
   preserved (disclosed, not hidden).
4. Untracked not-ignored files ride a tar stream; `--include` adds
   gitignored files (env files) at mode 0600.

Why not GitHub push+pull: the workspace has no GitHub credentials — no gh
CLI in the image, no Coder external auth. Every GitHub variant needs new
trust material on the VM; moving code between two machines the user already
controls needs none. Work comes BACK the same way (`tireless-handoff-pull`,
git-over-ssh in reverse — see "Hand-back"), and GitHub pushes keep
happening from the laptop.
A gh recipe (device-flow login, workspace→GitHub pushes) is a known v2 item.
One-shot escape hatch when the user insists on pushing from the workspace:
`ssh -A <alias> 'cd <dir> && git push origin <branch>'` — confirm
first and disclose that `-A` briefly exposes the local ssh agent to the VM.

What never travels in git mode: submodule contents, LFS blobs (warn; offer
`--tar-mode`), `.claude/settings.local.json` (machine-specific), and
gitignored secrets unless explicitly `--include`d (confirm-gated). Caveat:
`--tar-mode` outside any work tree ships the WHOLE directory, gitignored
env/secret files included — the skill discloses that before syncing; inside
a work tree tar-mode still respects `.gitignore`.

## How context travels: the brief, not the session file

Copying `~/.claude/projects/<escaped-cwd>/<session>.jsonl` to the workspace
and resuming was evaluated and REJECTED — do not re-litigate it from
scratch. It rides on at least four undocumented internals (cwd path
escaping, the jsonl record schema, server-side `bridge-session` ids, resume
lookup semantics), the transcript is soaked in local absolute paths the VM
does not have, versions skew (workspaces pin claude; laptops auto-update),
and the failure mode is silent — a confused agent, not an error. Its best
case is worse than the brief's: a deliberate distillation with remote paths
beats a raw transcript. Revisit only if an official session export/import
ships.

Briefs live at `~/.timeless/handoffs/<ws>-<utc-ts>.md` with a `latest.md`
symlink — the same shape as the proven `~/.timeless/clipboard/` convention,
outside the project so they survive `git clean`, branch switches, and
re-clones. Newer claude-code recipes bake a discovery note into the
workspace `~/.claude/CLAUDE.md`; `tireless-handoff-sync` appends the same
grep-guarded block on older workspaces.

## Brief template

Schema `tireless-handoff/v1`. Cap ~150 lines. Remote paths only. No secrets
— name variables, never values.

```markdown
# Handoff brief — <one-line task title>
schema: tireless-handoff/v1
created: <UTC ISO timestamp>
from: <agent + version, machine kind>
workspace: <ws>
project: /home/dev/<ws>/<repo>
branch: <branch>
head: <short sha>
origin: <ORIGIN_HOST from the probe, or none>

## Task
2–4 sentences: what the user asked for (their words where possible) and the
definition of done.

## Current state (verified done)
- Completed, tested work. Each bullet names the commit or file.

## In flight (started, NOT done)
- Exactly what was mid-edit: files, half-finished functions, failing tests.
  The synced tree carries these as uncommitted changes — say which.

## Next steps (ordered)
1. First step is a verification command ("run X, expect Y") to ground
   yourself before editing. Then concrete, imperative steps.

## Key files
- /home/dev/<ws>/<repo>/path — one-line role.

## Decisions + rationale
- Choice — why; rejected alternatives a fresh agent would plausibly
  re-propose.

## Dead ends (do not retry)
- Approach — why it failed (error text or reason). Mandatory section when
  anything was abandoned.

## How to run / test
- Exact commands, cd-prefixed, expected output. Long jobs: tmux idiom.

## Environment notes
- Env files copied (names only) or NOT copied; services, ports, anything the
  VM needs that the repo does not carry.

## Kickoff
The exact first instruction for the continuing agent.
```

## The launch, exactly

`tireless-handoff-launch` writes a tiny runner script on the workspace and
executes it — one quoting layer per hop, per `remote-exec.md`. The runner:

```sh
cd <target-dir>
tmux new-session -d -s tireless-continue -x 220 -y 50 \
  "$HOME/.local/bin/claude --dangerously-skip-permissions --remote-control '<fixed kickoff>'"
```

(The kickoff says "verify the project state it describes" — not "git
state" — so the same literal serves tar-mode handoffs.)

- The kickoff prompt is a FIXED literal pointing at
  `~/.timeless/handoffs/latest.md`. Task content never rides the command
  line — that is the load-bearing quoting rule.
- Full binary path always: `ssh ws 'cmd'` and tmux run non-login shells
  where the recipe's PATH export is absent.
- tmux provides a pty, so the interactive TUI runs fine with no client
  attached; `-x 220 -y 50` avoids the 80×24 default. Never pipe the agent
  to `tee` (non-tty stdout kills interactive mode) — logs, if wanted, via
  `tmux pipe-pane`.
- `--remote-control` makes the session steerable from claude.ai/code and
  the mobile app (Claude Code ≥2.1.51; needs claude.ai OAuth login, not an
  API key). The script auto-falls-back to launching without it
  (`REMOTE_CONTROL=off`) if the flag is not accepted. Codex has no CLI→web
  equivalent at 0.144.x — its steering path is tmux attach.
- `--dangerously-skip-permissions` (Codex:
  `--dangerously-bypass-approvals-and-sandbox`) is a product decision for
  autonomous continuation on the user's own single-tenant VM. It is always
  disclosed in the launch report. The attended alternative: skip the
  launch, give the user the web-terminal one-liner
  `claude "Read ~/.timeless/handoffs/latest.md and continue that work."`.

Monitoring from the local side stays within the long-job idiom:
`tireless-handoff-launch <ws> <dir> --status` (capped `capture-pane`), and
the session survives the laptop disconnecting entirely.

## Hand-back: how work returns, and how the laptop knows

`tireless-handoff-pull` is the sync in reverse, with the safety burden
flipped: sync may assume the workspace tree is disposable-ish (it parks
remote changes in stashes); pull must assume the LOCAL tree is precious.
Hence its three hard rules — fast-forward only (divergence is aborted, the
fetched `refs/tireless/handback` ref is left for a deliberate merge), the
remote uncommitted diff applies only when clean against the same base
(otherwise it is saved to `~/.timeless/handoffs/back/<ws>-<ts>.patch` and
reported), and untracked files never overwrite existing local paths
(identical-content files are recognized by blob hash and stay quiet, so
repeat pulls don't re-alarm; differing ones are listed in a skipped-file,
never clobbered). Gitignored remote files never travel back implicitly —
same posture as sync's confirm-gated `--include`.

The "laptop knows" mechanism is a local record, not a network probe: every
successful sync writes `~/.timeless/handoffs/out/<ws>--<rootid>.rec`
(KEY=val; `rootid` = cksum of the repo toplevel) with `RESOLVED=no`. Three
things read it: the plugin's SessionStart hook (`hooks/pending-handoff.sh`
— local file reads only, prints a one-line reminder in that project until
resolved), `tireless-handoff-state` (`PENDING_HANDOFFS`/`PENDING_WS`, which
the continue skill checks before ever syncing over newer work), and
`tireless-handoff-pull` itself (record supplies the default workspace,
target dir, and branch — zero-argument pull). `RESOLVED` flips to yes when
a pull (or a `tireless-handoff-check` probe) confirms parity: nothing on
the workspace — commits, dirty tree, untracked, stashes — that local
lacks. `--forget` deletes the record for abandoned or deleted workspaces.

`tireless-handoff-check` (the pre-approvable read-only wrapper for
`handoff-pull.sh --check`) fetches into the temp ref to get exact
ahead/behind counts but never touches the working tree, and also reports
whether the `tireless-continue` tmux session is still running — pull
refuses mid-flight pulls by default (`session_running`) because a working
agent's half-written tree is not a state worth copying; `--even-if-running`
overrides for deliberate snapshots.

Why not "auto-pull on session start": the hook stays offline-fast (<100 ms,
no ssh) so sessions never hang on a dead workspace, and a mutating pull
belongs behind the agent's permission prompt, not a hook. The hook nags,
the agent probes, the user approves the pull — same trust ladder as the
rest of the plugin.

## Failure modes at a glance

| Symptom | Meaning | Move |
|---|---|---|
| `SYNC=abort REASON=remote_ahead` | workspace has commits local lacks | `tireless-handoff-pull` them back first, or confirm-gated `--force-overwrite` (backup branch is created) |
| `SYNC=abort REASON=remote_detached` | workspace repo on a detached HEAD (agent mid-rebase?) | resolve it on the workspace, or `--force-overwrite` (HEAD gets a backup branch) |
| `SYNC=abort REASON=dir_not_repo` | target dir exists, not a repo | different `--target-dir`, or `--tar-mode` |
| `SYNC=abort REASON=dir_exists` | tar-mode target exists non-empty (overlay would diverge silently) | fresh `--target-dir`, or `--force-overwrite` to accept the overlay |
| `SYNC=abort REASON=not_a_repo/unborn_head` | no local git history | `--tar-mode` |
| `SYNC=abort REASON=detached_head` | no branch to materialize | pass `--branch` |
| `SYNC=fail` | ssh/git plumbing broke | fix skill; no blind retries |
| `LAUNCH=blocked REASON=not_installed` | no agent CLI on the VM | dashboard recipe, then re-run launch |
| `LAUNCH=blocked REASON=unauth` | agent CLI never signed in | one-time login in the web terminal, then re-run |
| `LAUNCH=blocked REASON=no_target_dir` | launch ran before sync (or wrong dir) | run `tireless-handoff-sync` first, then re-run |
| `LAUNCH=blocked REASON=no_brief` | no `latest.md` on the workspace (kickoff would dangle) | re-run the sync with `--brief` |
| `LAUNCH=ok` but `PANE_LAST` shows a prompt/menu | agent parked at a first-run gate (trust prompt, login, theme) | user answers it once via attach or the web terminal |
| `SYNC=ok` with `INCLUDE_BACKUP=<dir>` | remote copies of `--include` files differed and were saved | diff them on the workspace before assuming the laptop's env is right |
| `LAUNCH=exists` | continuation already running | attach, or confirm-gated `--stop` + relaunch |
| `LAUNCH=fail` + ssh-ish `DETAIL` | connection broke mid-launch | fix skill; no blind retries |
| `LAUNCH=fail` "exits immediately" | expired login / broken install | user runs the agent attended in the web terminal; everything is already synced |
| `SYNC=fail` "could not archive" | a file vanished/changed mid-archive (live dev server writing) | retry once; if persistent, stop the writer first |
| huge repo, push times out | first push moves all objects | re-run with a raised Bash timeout; later pushes are delta-cheap |
| `PULL=abort REASON=session_running` | workspace agent still working | `--status`/attach and wait, confirm-gated `--stop`, or `--even-if-running` snapshot |
| `PULL=abort REASON=ff_blocked` | local dirty overlaps workspace commits (usually the same changes the agent committed) | `git stash` + re-pull; stash drop if redundant, else pop + hand-merge |
| `PULL=abort REASON=diverged` | both sides committed | merge `refs/tireless/handback` deliberately, re-pull for the remainder |
| `PULL=abort REASON=branch_mismatch` | local checkout on another branch | `git checkout <branch>` first |
| `PULL=abort REASON=remote_not_repo` | tar-mode handoff (no git there) | copy what's needed over ssh, or remote `git init` + commit first |
| `PULL=ok` with `DIRTY_SAVED=path` | remote diff conflicts with local edits | apply the saved patch by hand when ready |
| `PULL=ok` with `UNTRACKED_SKIPPED>0` | remote untracked files differ from same-named local ones | diff against `SKIPPED_LIST`, decide per file |
| record nags but workspace is gone | stale pending-handoff record | `tireless-handoff-pull --forget` |
