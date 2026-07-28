---
name: connect
description: Connect this agent to the user's Tireless cloud dev computer (tirelesscode.com). Use when the user says "connect to my workspace", "set up tireless", "link my cloud dev box", mentions an ssh <workspace>.tireless host that is not working yet, or asks to get their Tireless workspace reachable from this machine. Installs the tireless CLI and clipboard companion, authenticates, writes SSH config, and verifies the connection end to end. Idempotent — safe to re-run any time.
allowed-tools: Bash(tireless-preflight*), Bash(tireless-verify*), Bash(tireless list*), Bash(tireless ping*), Bash(tireless users show*), Bash(tireless version*)
---

# Connect to a Tireless workspace

Goal: end this flow connected and verified — `ssh <workspace>.tireless` works,
clipboard paste works, and the user can hand you work. Every step is
idempotent; skip steps whose preflight key already says ok.

## Ground rules (non-negotiable)

- **Tokens never appear in chat.** Never ask the user to paste a token or
  session cookie into the conversation; never echo, print, or log one. All
  interactive logins happen in the USER'S OWN terminal — you tell them the
  exact command, they run it there and reply "done". If a user pastes a token
  into chat anyway, tell them to revoke it immediately. Re-minting an EXPIRED
  per-cell Coder session is NOT interactive and is yours to do: run
  `tireless-session-heal` (server-minted, no browser, no paste). Never
  substitute `tireless-connect login` for it — when the platform token is also
  dead that command opens a browser and blocks on the loopback callback, which
  hangs your Bash tool and the session with it.
- **Never** run `tireless start|stop|delete|create` or call the Coder API.
  Lifecycle belongs to the platform reconciler — see the lifecycle reference
  (Claude Code: `${CLAUDE_PLUGIN_ROOT}/reference/lifecycle.md`; Codex/Cursor:
  `~/.agents/skills/tireless/reference/lifecycle.md`).
- **Never create a workspace from this skill.** Creation is confirm-gated
  behind the `tireless_create_workspace` MCP tool and requires the user's
  explicit yes (it bills their card). See the workspace skill.

## Script locations

- Claude Code (plugin): the wrappers `tireless-preflight`, `tireless-verify`,
  `tireless-session-heal`, `tireless-ssh-clean`, `tireless-project-note` are
  already on your Bash PATH.
- Codex / Cursor (installer): the same scripts live under
  `~/.agents/skills/tireless/scripts/` — `sh …/preflight.sh`,
  `sh …/verify.sh <workspace>`, `sh …/session-heal.sh`, `sh …/ssh-clean.sh`,
  `sh …/project-note.sh <alias> <dir> <branch>`.

## Step 0 — preflight

Run `tireless-preflight` (or the Codex/Cursor path above). It prints KEY=val
lines; branch on exact string matches:

| Key | Meaning |
|---|---|
| `CLI` | `tireless` CLI installed |
| `AUTH` | `ok` / `expired` (routine 8h expiry — heals headlessly, see below) / `error` (network, not auth — do not heal) / `missing` (never set up here) |
| `SSHCFG` | `*.tireless` block in `~/.ssh/config` |
| `SSHCFG_STALE` + `SSHCFG_STALE_OURS` | a dead stock-Coder block lingers, and whether it is provably ours to remove |
| `CLIP` | clipboard companion installed + wired (`stale` = installed, not wired) |
| `CONNECT` | `tireless-connect` MCP binary present |
| `PATHOK` | `~/.local/bin` on PATH |
| `APP_ORIGIN` | platform origin (default `https://app.tirelesscode.com`) |

If everything is `ok`, jump to Step 5 and just verify.

## Step 1 — install the CLI + clipboard companion (when CLI=missing)

```
curl -fsSL https://app.tirelesscode.com/install.sh | sh -s -- --no-login
```

`--no-login` skips the interactive browser login — that step reads /dev/tty
and would hang your Bash tool. Auth happens in Step 2 instead.

- Multi-region platforms: the served installer only bakes in a default region
  when exactly ONE is active. If the output says `no region given` (or the
  preflight still reports `CLI=missing` afterwards), list the region ids with
  `curl -fsSL https://app.tirelesscode.com/install.sh | grep "CP_URL="`, ask the
  user which region their workspace lives in, then re-run:
  `curl -fsSL https://app.tirelesscode.com/install.sh | sh -s -- --no-login --region <regionId>`.
- If `PATHOK=no`: use `~/.local/bin/tireless` and `~/.local/bin/tireless-clip`
  explicitly this session, and offer (ask first) to append
  `export PATH="$HOME/.local/bin:$PATH"` to the user's shell profile.
- Windows local machine: the installer refuses by design (no SSH/clip client
  yet). Point the user at the dashboard editors and the clipboard drop-box
  page (see the clipboard skill), and stop here.

## Step 2 — authenticate

**Preferred — MCP tools available** (tool names start with `tireless_`):

1. Call `tireless_status` to see what is missing.
2. If unauthenticated, call `tireless_login`; give the user the authorize URL
   it returns and wait for it to report completion.
3. Call `tireless_connect_workspace` — it runs the whole idempotent pipeline
   (CLI install, login, ssh config, clip setup, resume-if-suspended) and
   returns a connection card. It re-mints expired per-cell Coder sessions
   headlessly on its own; only if it returns an explicit `action_required`
   card do you direct the user to run the command it names in their own
   terminal — then wait for "done".

**`AUTH=expired` — handle it yourself, silently.** This is the ordinary
overnight state, not a problem to report. Run `tireless-session-heal`; it
re-mints through the platform (server-minted, no browser, no paste, no token
in chat) and prints `SESSION=healed`. Re-run the preflight and carry on
without mentioning it, unless it returns `SESSION=action_required` — then
follow its `NEXT=` line. (`AUTH=error` is NOT this: that is a network or edge
problem, and healing into it is wrong — go to the fix skill.)

**Fallback — no MCP tools** (`AUTH=missing`):

- If `CONNECT=ok`: run `tireless-session-heal` first — with a valid stored
  platform session it establishes the Coder session headlessly. Only when it
  reports `SESSION=action_required` does the user get involved: "Run
  `tireless-connect login` in your own terminal. A browser opens for a
  one-click approval; if a region asks, it opens that region's Coder sign-in
  automatically — no button to click, just paste the token it shows into that
  terminal, never here. Say 'done' when it finishes."
  Never run `tireless-connect login` from your OWN Bash tool: with a dead
  platform token it opens a browser and blocks on the loopback callback,
  which hangs your session. `tireless-session-heal` cannot do that.
- If `CONNECT=missing`: install it first
  (`curl -fsSL https://app.tirelesscode.com/connect/install.sh | sh`), then the
  `tireless-connect login` flow above. (A raw `tireless login <cpUrl>` is NOT
  a substitute — it writes a default-dir session that no regional ssh config
  reads.)
- After "done": re-run the preflight. `AUTH=ok` means proceed; anything else
  means switch to the fix skill.

## Step 3 — SSH config (when SSHCFG=missing)

```
tireless-connect setup
```

Writes the marker-wrapped Include in `~/.ssh/config` plus per-region
fragment files (`Host *.<region>.tireless` with a ProxyCommand — no host-key
prompts, safe for non-interactive use). Never run bare
`tireless config-ssh --yes`: it targets the stock coderv2 config dir and
writes exactly the dead block described next.

`SSHCFG_STALE=yes` + `SSHCFG_STALE_OURS=yes`: a dead block from an old run of
that command is still in `~/.ssh/config`. Run `tireless-ssh-clean` — it
backs the file up first and removes only blocks whose every ProxyCommand runs
the Tireless CLI. Mention it in one line afterwards; don't make a
conversation of it. With `SSHCFG_STALE_OURS=no` the block may belong to a
real Coder deployment the user runs: say it is there, and leave it alone.

## Step 4 — clipboard bridge (when CLIP=stale|missing)

- `CLIP=missing`: `curl -fsSL https://app.tirelesscode.com/clip/install.sh | sh`
  (downloads the companion AND runs its setup).
- `CLIP=stale`: `tireless-clip setup` (use `~/.local/bin/tireless-clip` if
  not on PATH).

## Step 5 — pick the workspace

`tireless list` (pre-approved, read-only).

- Exactly one workspace: use it.
- Several: ask the user which one.
- None: do NOT create one. Explain that creating a workspace bills their
  card, and offer either the dashboard or the confirm-gated
  `tireless_create_workspace` MCP tool (workspace skill has the rules).
- Suspended/stopped: resume via `tireless_workspace_action`
  (`{"action":"resume"}`) and follow `tireless_watch_state` until ready; with
  no MCP tools, send the user to the dashboard. Never `tireless start`.

**Orgs: one login covers all of them.** A Tireless account can belong to several
orgs (teams), and this connector already sees the workspaces of EVERY org the
user belongs to — the list is a union, not a single org. `tireless_status` tags
each row with `org` / `org_id`; group by that when you show the list, because
otherwise two orgs read as one flat pile.

Consequences to get right:

- A workspace the user "can't reach in the other org" is almost always just an
  unfamiliar name in this same list. Check the list before concluding anything.
- Do **not** reach for `tireless_switch_account` for an org problem. It clears
  the session and every regional Coder session, and changes nothing when both
  orgs sit under one login. It is only for a genuinely different account.
- Creating is the one thing that is org-specific: without an explicit
  `team_id`, `tireless_create_workspace` lands in the account's default org. If
  the confirm-gated card comes back with `team_choice_required`, ask the user
  WHICH org before creating — a server in the wrong org is billed to the wrong
  place and is awkward to move.

## Step 6 — verify

Run `tireless-verify <workspace>` (or the Codex/Cursor script path). Prefer
passing the `ssh_alias` from the connection card when you have one; a bare
name gets resolved against the regional suffixes automatically.

- `VERIFY=ok` + `ALIAS=…` + `HOST=…`: connected. Use that `ALIAS` (e.g.
  `myws.eu-central.tireless`) in every later ssh command — the bare
  `<ws>.tireless` form only exists on legacy single-region installs.
- `VERIFY=fail`: read `SSH_EXIT` and `DETAIL`, then switch to the fix skill's
  decision tree. Do not retry blindly.

Optionally also verify paste (clipboard skill): ask the user to copy a
screenshot, then check for the PNG magic over ssh.

## Step 7 — the project stanza

**Usually there is nothing to do here.** The stanza is written automatically
by `tireless-handoff-sync`, because that is the only command that knows the
real remote directory and branch — and the stanza asserts the project *is
synced to* the workspace, which after a bare connect is simply not true. So:

- Came here from a handoff (`continue` skill)? Already done — skip.
- Plain connect, no sync? Write nothing. Offer instead: "want me to sync this
  project to the workspace?" — the sync writes the note as part of its job.
- User explicitly asks for the note *and* the project already lives on the
  workspace at a path they name, use:

```
tireless-project-note <ALIAS> <remote-dir> <branch>
```

(Codex/Cursor: `sh ~/.agents/skills/tireless/scripts/project-note.sh <ALIAS> <remote-dir> <branch>`.)

It is marker-wrapped, refreshed in place on later runs, and backs the file up
outside the repo first. Report it in one line — including `TRACKED=yes` when
the file is under git, because the stanza names a machine-specific alias that
would reach teammates if committed. Never invent a `<remote-dir>`/`<branch>`
to satisfy the arguments: writing a wrong path into persistent project memory
misleads every future session in that repo.

## Step 8 — report

Tell the user what now works, concretely: "Connected. I can run commands on
`<workspace>` over ssh, start a local Claude Code session connected to it, open
VS Code/Cursor in its remote project, share preview ports, and use Ctrl+V image
paste in agents on the workspace."

Connecting also writes a friendly `<workspace>.tireless` ssh alias into the
managed config, so the workspace shows up as a ready-to-pick host in IDE remote
pickers instead of the user hand-filling an "Add SSH host" dialog. The
`ide_hosts` step in `tireless_connect_workspace` reports it. Two things to relay
accurately:

- VS Code, Cursor and Antigravity list it automatically (they read `~/.ssh/config`
  and follow its `Include`).
- Orca keeps its own copy of the host list, so it needs **Settings → SSH Hosts →
  Import** once. After that it stays in sync. Never hand-edit Orca's data file —
  the running app owns it and will overwrite outside writes.

The canonical long alias keeps working unchanged; the short one is additive.

If the user's original request included VS Code or another external surface,
continue after verification by calling `tireless_open_editor` with that editor.
For Claude Code, this verified plugin session is already connected; launching
`editor: "claude"` opens a SEPARATE new terminal window. Only do that when the
user explicitly asked for a fresh/new session. If “open it in a terminal” /
“get me into the server” is ambiguous, ASK first — “Work here in this session,
or open a new Claude Code terminal window?” — rather than spawning a new window.
Do not make them repeat the request.
