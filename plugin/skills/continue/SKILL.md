---
name: continue
description: Continue the current local coding session on the user's Tireless cloud workspace. Use when the user says "continue this on my workspace/server", "hand this off to my cloud dev computer", "pick this up on the server", "move this work/session to my workspace", or wants the workspace agent to keep working after they step away. Syncs the branch + uncommitted changes + selected env files over ssh, writes a handoff brief with the session context, and starts Claude Code (or Codex) on the workspace in tmux — steerable from claude.ai.
allowed-tools: Bash(tireless-handoff-state*), Bash(tireless-verify*), Bash(tireless-urls*), Bash(tireless list*), Bash(tireless ping*)
---

# Continue this session on a Tireless workspace

Hand the CURRENT work — code state AND session context — to an agent running
on the user's cloud workspace. Three commands do all the work; your job is
the decision tree between them and writing a good brief. Full background:
`${CLAUDE_PLUGIN_ROOT}/reference/handoff.md` (Codex/Cursor:
`~/.agents/skills/tireless/reference/handoff.md`).

Ground rules (same as every tireless skill): tokens and secrets never appear
in chat or in the brief; lifecycle only via `tireless_workspace_action`
(restart/suspend/resume — never `tireless start|stop|delete|create`);
reserved ports 22, 13337, 6800, 6801, 6810, 19985 are never shared.

## Step 1 — snapshot the local repo

Run `tireless-handoff-state` (Codex/Cursor:
`sh ~/.agents/skills/tireless/scripts/handoff-state.sh`) from the project
directory and branch on its KEY=val output:

- `REPO=ok` → keep `REPO_ROOT` for Step 5 (the sync must run from there).
- `UNBORN=yes` → the sync will use `--tar-mode`; inside a work tree it still
  respects `.gitignore`. Tell the user (no history travels).
- `REPO=none` → `--tar-mode` ships the WHOLE directory — including any
  gitignored env/secret files, with no Step 3 gate. Say that explicitly and
  get a go-ahead before syncing.
- `DETACHED=yes` → ask for a branch name to materialize on the workspace
  (default `tireless/handoff-<utc-timestamp>`), pass it as `--branch`.
- `SUBMODULES=yes` / `LFS=yes` → warn: submodule contents and LFS blobs do
  NOT travel over the handoff; offer `--tar-mode` if those files matter.
- `ENV_CANDIDATES` → keep for Step 3; `ORIGIN_HOST` → goes into the brief
  header (Step 4).

## Step 2 — resolve the workspace

1. Not yet connected in this conversation? Follow the connect skill first.
2. `tireless_list_workspaces`: exactly one → use it; several → ask the user
   which one; none → stop (creation is the workspace skill's confirm-gated
   flow — never create from here).
3. Suspended → `tireless_workspace_action` `{"action":"resume"}`, then
   `tireless_watch_state` until ready.
4. `tireless-verify <ws>` — `VERIFY=fail` → switch to the fix skill; do not
   hand off over a broken connection.

Default remote project dir is `/home/dev/<ws>/<REPO_NAME>` (with
`REPO=none`: the basename of the current directory). On a first handoff,
confirm it with the user; pass `--target-dir` if they want another.

## Step 3 — env files (confirm-gated)

(`REPO=ok`/`UNBORN=yes` only — with `REPO=none` everything ships anyway;
Step 1's disclosure covers it.) Git will not carry gitignored env files.
Show the user `ENV_CANDIDATES`
(paths only — NEVER print or read their contents) and ask which to copy;
also ask whether the project needs other gitignored files (service-account
JSON, certs). Each approved path becomes an `--include` flag in Step 5. If
the user declines, proceed — but record in the brief that env files were not
copied and the project may not run until they exist.

## Step 4 — write the handoff brief

Write the brief to a local temp file (e.g. `/tmp/tireless-handoff-<ws>.md`)
with your Write tool. This file IS the session handoff — the workspace agent
knows only what you put here. Follow the template in
`reference/handoff.md#brief-template` (schema `tireless-handoff/v1`), and
enforce on yourself:

- **Remote paths only** — translate every local absolute path to
  `/home/dev/<ws>/<repo>/...`.
- **Dead ends are mandatory** when you abandoned any approach this session —
  they are the highest-value section for the next agent.
- **No secrets.** Name env variables, never their values.
- Next steps start with a verification command ("run X, expect Y") so the
  remote agent grounds itself before editing.

## Step 5 — sync (one command)

```sh
tireless-handoff-sync <ws> --brief /tmp/tireless-handoff-<ws>.md \
  [--include .env]... [--branch <name>] [--target-dir <dir>] [--tar-mode]
```

(Codex/Cursor: `sh ~/.agents/skills/tireless/scripts/handoff-sync.sh <ws> ...`.)

Run it from `REPO_ROOT` (Step 1 output) — in tar mode the script ships the
current directory verbatim. One prompt-gated call moves everything: commits,
uncommitted diff, untracked files, includes, brief (plus the CLAUDE.md +
AGENTS.md discovery notes on older workspaces). Branch on the FIRST output
line:

- `SYNC=ok MODE=git` → check `HEAD_SHA` matches the local probe; note
  `REMOTE_STASHED=yes` (report the stash to the user — the brief gets a
  "Parked remote changes" section automatically) and `BACKUP_BRANCH`.
- `SYNC=ok MODE=tar` → whole-tree snapshot: no `HEAD_SHA` check, no
  `DIRTY_APPLIED`/`UNTRACKED_SENT`/`REMOTE_STASHED` keys, and remote files
  were overwritten in place.
- `SYNC=abort REASON=remote_ahead` → the workspace has commits the local
  branch lacks (an agent worked there since the last handoff). Offer the two
  paths from `NEXT=`: fetch them back and merge locally (preferred), or
  re-run with `--force-overwrite` — only after the user explicitly confirms
  overwriting, and tell them the backup branch name afterwards.
- `SYNC=abort` (other reasons) → the `NEXT=` line says what to do.
- `SYNC=fail` → treat like a broken connection: fix skill, no blind retries.

## Step 6 — launch the continued session

```sh
tireless-handoff-launch <ws> <target-dir> --agent claude
```

(Codex/Cursor: `sh ~/.agents/skills/tireless/scripts/handoff-launch.sh <ws> <dir>`;
pass `--agent codex` when the workspace agent should be Codex.)

- `LAUNCH=ok` → report: the session name, `ATTACH_SSH`, the dashboard web
  terminal (from `tireless-urls <ws>` / the `links` object) + `tmux attach
  -t tireless-continue`, and — when `REMOTE_CONTROL=on` — that the session
  is steerable from claude.ai/code and the Claude mobile app.
  `REMOTE_CONTROL=off` → steering is via tmux attach only; say so.
- `LAUNCH=exists` → a continuation is already running: offer attach, or
  `--stop` then relaunch (confirm before killing it).
- `LAUNCH=blocked REASON=not_installed` → the agent CLI is not on the
  workspace: point the user at the dashboard recipe (workspace page →
  Recipes → Claude Code/Codex). Everything is already synced — once
  installed, re-run the launch command.
- `LAUNCH=blocked REASON=unauth` → one-time sign-in: user opens the web
  terminal, runs `claude` (or `codex`), completes the login THERE (never
  paste tokens into this chat), says "done" → re-run the launch. Codex
  browser-redirect logins may need `ssh -L 1455:localhost:1455
  <ws>.tireless` run by the user in their own terminal. Still blocked after
  one retry → don't loop; hand the user the attended one-liner below.
- `LAUNCH=blocked REASON=no_target_dir` → sync didn't run (or wrong dir):
  back to Step 5.
- `LAUNCH=fail` → read `DETAIL`. ssh-level breakage ("unreachable", "lost
  ssh") → fix skill, no blind retries. "exits immediately" → likely expired
  credentials or a broken install: have the user run the agent attended in
  the web terminal (`claude "Read ~/.timeless/handoffs/latest.md and
  continue that work."`) — everything is already synced.
- Later check-ins: `tireless-handoff-launch <ws> <dir> --status` (capped
  pane capture); stop with `--stop`.

The launch runs the agent with permission prompts bypassed
(`--dangerously-skip-permissions` / Codex sandbox bypass) — a deliberate
product decision for the user's own single-tenant VM. Disclose it in one
line when reporting the launch; if the user objects, stop the session and
tell them to drive it attended via the web terminal instead.

## Step 7 — report

Tell the user, concretely: what synced (branch, sha, dirty/untracked counts,
env files by name), where (`target-dir`), that the brief is at
`~/.timeless/handoffs/latest.md`, how the session is running and how to
watch/steer it, and how to bring work back later:

```sh
git fetch ssh://<ws>.tireless/home/dev/<ws>/<repo> <branch>
```

(work returns to the laptop with a plain fetch — pushing to GitHub still
happens from the laptop; the workspace has no GitHub credentials). After a
`MODE=tar` sync there is no git bring-back: the workspace copy is now the
canonical one — say so, and suggest the remote agent `git init` there if
history matters going forward.

## If the user only wants to keep driving from here

No launch needed: sync (Steps 1–5) still pays off — the brief plus synced
tree mean any future session, local or remote, can pick the work up. Then
keep working over `ssh <ws>.tireless` per the workspace skill.
