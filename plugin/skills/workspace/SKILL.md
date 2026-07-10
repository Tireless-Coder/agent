---
name: workspace
description: Work on a connected Tireless workspace - run commands remotely, open editors, and manage preview ports. Use when running, building, or testing anything on the user's Tireless cloud dev computer or server (ssh <workspace>.tireless), opening Claude Code/VS Code/Cursor/web terminal/desktop on it, sharing or previewing a port, restarting/suspending/resuming a workspace, or creating a new one.
allowed-tools: Bash(tireless-urls*), Bash(tireless-verify*), Bash(tireless list*), Bash(tireless ping*), Bash(tireless users show*)
---

# Working on a Tireless workspace

Remote work happens over the agent's native Bash with plain ssh — there is
deliberately NO MCP exec tool, so your client's own permission system governs
every remote command. Full idiom reference (Claude Code:
`${CLAUDE_PLUGIN_ROOT}/reference/remote-exec.md`; Codex/Cursor:
`~/.agents/skills/tireless/reference/remote-exec.md`).

## Remote-exec idioms (always)

- **Fresh shell every call.** `ssh <ws>.tireless 'cmd'` starts a new login
  shell in `$HOME` each time — nothing persists. ALWAYS cd-prefix:
  `ssh <ws>.tireless 'cd <dir> && <cmd>'`.
- **Probes**: add `-o BatchMode=yes -o ConnectTimeout=10` so a broken
  connection errors fast instead of hanging your Bash tool.
- **Long jobs (>2 min)**: run detached and poll —
  `ssh <ws>.tireless 'cd <dir> && tmux new -d -s job1 "<cmd> 2>&1 | tee ~/job1.log"'`
  then poll with `ssh <ws>.tireless 'tail -20 ~/job1.log'`.
- **Cap output**: append `| tail -100` (or grep) to anything chatty — full
  build logs burn your context for nothing.
- Use only the `<ws>.tireless` alias. Never `ssh dev@<ip>` with relaxed
  host-key checking, and never wrap remote exec in an MCP tool.

## Open editors and URLs

Opening an editor is a connect-then-launch flow. If this conversation has not
already received a successful connection card for the selected workspace:

1. Resolve the workspace with `tireless_list_workspaces` (ask only when more
   than one workspace matches the user's request).
2. Call `tireless_connect_workspace` and handle any `action_required` card.
3. Once its connection state is `ready`, run `tireless-verify <workspace>`
   (Codex/Cursor:
   `sh ~/.agents/skills/tireless/scripts/verify.sh <workspace>`).
   `VERIFY=fail` means switch to the fix skill; do not launch.
4. Only after `VERIFY=ok`, call `tireless_open_editor` with the requested
   editor.

This makes “open my server in VS Code” one intent: the user should not have to
ask separately for SSH setup, resume, verification, and launch.

In the Claude Code plugin itself, a plain “open/connect my server in Claude
Code” means connect THIS session; the successful connection card plus
`VERIFY=ok` completes the request. Call `tireless_open_editor` with
`editor: "claude"` only when the user explicitly asks for a fresh/new/another
Claude Code session, so the plugin does not open a duplicate window
unexpectedly.

Run `tireless-urls <ws> [slug|port]`
(Codex/Cursor: `sh ~/.agents/skills/tireless/scripts/urls.sh <ws> [slug|port]`)
to get KEY=val links, or take the `links` object from `tireless_get_workspace`
/ `tireless_connect_workspace` (authoritative — includes code, desktop,
chrome, terminal, vscode, cursor, clipboard).

- Fresh Claude Code session: call `tireless_open_editor` with
  `editor: "claude"`. It opens a new LOCAL Claude Code terminal with a visible,
  prefilled request to connect through the Tireless plugin or the already
  configured native SSH alias. Tell the user to review it and press Enter. This
  is intentionally not a fake remote `cwd` deep link. If the URL handler does
  not open, use the tool's returned prompt with a manually started `claude`.
- VS Code: `vscode://vscode-remote/ssh-remote+<ws>.tireless/home/dev/<ws>`
- Cursor: `cursor://vscode-remote/ssh-remote+<ws>.tireless/home/dev/<ws>`
- Web terminal / desktop: use the links from the tools above.
- Open deeplinks for the user with `open <url>` (macOS) / `xdg-open <url>`
  (Linux), or the `tireless_open_editor` MCP tool.

## Preview ports

Share a dev server publicly only via the `tireless_share_port` MCP tool
(never the Coder CLI/API). Reserved — can NEVER be shared: **22, 13337,
6800, 6801, 6810, 19985**. They are the workspace itself (sshd, code-server,
desktop, clipboard); sharing one would expose an unauthenticated control
surface. If the user asks for one of these, explain that and offer the proper
surface (editor link, terminal link, clipboard page) instead.

## Lifecycle — HARD PROHIBITION

Never run `tireless start|stop|delete|create|update`, and never mutate
workspaces through the Coder API. The platform reconciler owns
`desired_state`; out-of-band mutations are detected and reverted, and can
leave the workspace inconsistent — the lifecycle reference (Claude Code:
`${CLAUDE_PLUGIN_ROOT}/reference/lifecycle.md`; Codex/Cursor:
`~/.agents/skills/tireless/reference/lifecycle.md`) explains why.

Allowed lifecycle, always through the platform:

- `tireless_workspace_action` with `{"action": "restart"}`, `"suspend"`, or
  `"resume"` — those three only. There is no delete action anywhere;
  deletion is dashboard-only, by the user.
- `tireless_watch_state` to follow a transition until ready.
- No MCP tools available → send the user to the dashboard.

## Creating a workspace (confirm-gated — paid resources)

Only via the `tireless_create_workspace` MCP tool, and only like this:

1. Call it WITHOUT `confirm` first. It will not create anything; it returns
   `{"requires_confirmation": true, "plans": [...], "message": ...}`.
2. Show the user the plans and prices and ask plainly: creating this
   workspace starts paid resources billed to their card — do they want it?
3. Only after the user explicitly says yes IN THIS CONVERSATION may you call
   the tool again with `{"confirm": true, ...}` — and quote their exact
   confirmation ("yes, create the starter workspace") when you do.
4. Never pass `confirm: true` on the first call, never infer consent from an
   earlier task description, and never create via CLI, API, or dashboard
   automation.
