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
  into chat anyway, tell them to revoke it immediately.
- **Never** run `tireless start|stop|delete|create` or call the Coder API.
  Lifecycle belongs to the platform reconciler — see the lifecycle reference
  (Claude Code: `${CLAUDE_PLUGIN_ROOT}/reference/lifecycle.md`; Codex/Cursor:
  `~/.agents/skills/tireless/reference/lifecycle.md`).
- **Never create a workspace from this skill.** Creation is confirm-gated
  behind the `tireless_create_workspace` MCP tool and requires the user's
  explicit yes (it bills their card). See the workspace skill.

## Script locations

- Claude Code (plugin): the wrappers `tireless-preflight`, `tireless-verify`
  are already on your Bash PATH.
- Codex / Cursor (installer): run
  `sh ~/.agents/skills/tireless/scripts/preflight.sh` and
  `sh ~/.agents/skills/tireless/scripts/verify.sh <workspace>`.

## Step 0 — preflight

Run `tireless-preflight` (or the Codex/Cursor path above). It prints KEY=val
lines; branch on exact string matches:

| Key | Meaning |
|---|---|
| `CLI` | `tireless` CLI installed |
| `AUTH` | Coder session valid (`tireless list` exits 0) |
| `SSHCFG` | `*.tireless` block in `~/.ssh/config` |
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
   returns a connection card. When it needs the per-cell Coder login, it will
   tell you to direct the user to run a command in their own terminal — do
   exactly that and wait for "done".

**Fallback — no MCP tools** (`AUTH=missing`):

- If `CONNECT=ok`: tell the user — "Run `tireless-connect login` in your own
  terminal. A browser opens for a one-click approval; if a region asks, it
  opens that region's Coder sign-in automatically — no button to click, just
  paste the token it shows into that terminal, never here. Say 'done' when it
  finishes."
- If `CONNECT=missing`: tell the user to run `tireless login <cpUrl>` in
  their own terminal instead, then say "done". To find `<cpUrl>` read the CP
  case from the served installer (read-only):
  `curl -fsSL https://app.tirelesscode.com/install.sh | grep "CP_URL="` — or the
  user can copy the command from their dashboard SSH page.
- After "done": re-run the preflight. `AUTH=ok` means proceed; still
  `missing` means switch to the fix skill.

## Step 3 — SSH config (when SSHCFG=missing)

```
tireless config-ssh --yes
```

Writes the managed `*.tireless` host block (ProxyCommand — no host-key
prompts, safe for non-interactive use).

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

## Step 6 — verify

Run `tireless-verify <workspace>` (or the Codex/Cursor script path).

- `VERIFY=ok` + `HOST=…`: connected.
- `VERIFY=fail`: read `SSH_EXIT` and `DETAIL`, then switch to the fix skill's
  decision tree. Do not retry blindly.

Optionally also verify paste (clipboard skill): ask the user to copy a
screenshot, then check for the PNG magic over ssh.

## Step 7 — offer the project stanza

Ask: "Want me to add a remote-exec note to this project's CLAUDE.md /
AGENTS.md so future sessions use the workspace correctly?" Only on yes,
append:

```
## Tireless workspace
Remote workspace `<workspace>`: run commands as
`ssh <workspace>.tireless 'cd <dir> && <cmd>'` — every ssh call is a fresh
shell, so always cd-prefix. Probes: `-o BatchMode=yes -o ConnectTimeout=10`.
Jobs >2 min: `tmux new -d`. Cap output with `| tail -100`.
Never `tireless start|stop|delete|create`; lifecycle only via the Tireless
dashboard or tireless_* MCP tools.
```

## Step 8 — report

Tell the user what now works, concretely: "Connected. I can run commands on
`<workspace>` over ssh, start a local Claude Code session connected to it, open
VS Code/Cursor in its remote project, share preview ports, and use Ctrl+V image
paste in agents on the workspace."

If the user's original request included VS Code or another external surface,
continue after verification by calling `tireless_open_editor` with that editor.
For Claude Code, this verified plugin session is already connected; launch
`editor: "claude"` only if they explicitly asked for a fresh/new session. Do
not make them repeat the request.
