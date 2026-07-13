# Session handoff to a workspace — design notes + brief template

How "continue this on my workspace" works, why it works that way, and the
exact brief format. The continue skill is the walkthrough; this is the
background an agent (or maintainer) needs when something is off-script.

## How code travels: direct git-over-ssh, no GitHub

`tireless-handoff-sync` pushes straight to the workspace through the
existing `<ws>.tireless` alias:

1. `git push ssh://<ws>.tireless<target-dir> +HEAD:refs/tireless/handoff` —
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
controls needs none. Work comes BACK the same way (`git fetch
ssh://<ws>.tireless/...`), and GitHub pushes keep happening from the laptop.
A gh recipe (device-flow login, workspace→GitHub pushes) is a known v2 item.
One-shot escape hatch when the user insists on pushing from the workspace:
`ssh -A <ws>.tireless 'cd <dir> && git push origin <branch>'` — confirm
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

## Failure modes at a glance

| Symptom | Meaning | Move |
|---|---|---|
| `SYNC=abort REASON=remote_ahead` | workspace has commits local lacks | fetch back + merge, or confirm-gated `--force-overwrite` (backup branch is created) |
| `SYNC=abort REASON=dir_not_repo` | target dir exists, not a repo | different `--target-dir`, or `--tar-mode` |
| `SYNC=abort REASON=not_a_repo/unborn_head` | no local git history | `--tar-mode` |
| `SYNC=abort REASON=detached_head` | no branch to materialize | pass `--branch` |
| `SYNC=fail` | ssh/git plumbing broke | fix skill; no blind retries |
| `LAUNCH=blocked REASON=not_installed` | no agent CLI on the VM | dashboard recipe, then re-run launch |
| `LAUNCH=blocked REASON=unauth` | agent CLI never signed in | one-time login in the web terminal, then re-run |
| `LAUNCH=blocked REASON=no_target_dir` | launch ran before sync (or wrong dir) | run `tireless-handoff-sync` first, then re-run |
| `LAUNCH=exists` | continuation already running | attach, or confirm-gated `--stop` + relaunch |
| `LAUNCH=fail` + ssh-ish `DETAIL` | connection broke mid-launch | fix skill; no blind retries |
| `LAUNCH=fail` "exits immediately" | expired login / broken install | user runs the agent attended in the web terminal; everything is already synced |
| `SYNC=fail` "could not archive" | a file vanished/changed mid-archive (live dev server writing) | retry once; if persistent, stop the writer first |
| huge repo, push times out | first push moves all objects | re-run with a raised Bash timeout; later pushes are delta-cheap |
