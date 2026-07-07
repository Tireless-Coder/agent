# Tireless Agent Connector

Connect AI coding agents — Claude Code, Codex, Cursor — to your
[Tireless](https://tirelesscode.com) cloud dev computer. Install one thing,
then tell your agent **"connect to my workspace"**: it installs the
`tireless` CLI and clipboard companion, authenticates, writes your SSH
config, verifies the connection, and from then on runs commands on your
workspace, opens editors, shares preview ports, fixes clipboard paste, and
diagnoses its own failures.

## Install

**Claude Code**

```
claude plugin marketplace add Tireless-Coder/agent && claude plugin install tireless@tireless
```

**Codex & Cursor** — paste into the agent:

```
curl -fsSL https://app.tirelesscode.com/connect/install.sh | sh
```

Then say: *"connect to my workspace"*.

## What's inside

| Piece | What it does |
|---|---|
| `plugin/skills/connect` | Flagship onboarding: preflight → install → auth → ssh config → clipboard → verify. Idempotent. |
| `plugin/skills/fix` | Doctor decision tree; every `E_*` fix code maps to exactly one action; dead ends emit a support summary. |
| `plugin/skills/workspace` | Remote-exec idioms (`ssh <ws>.tireless 'cd … && …'`), editor deeplinks, preview ports, lifecycle guardrails. |
| `plugin/skills/clipboard` | Ctrl+V paste bridge verification and repair, drop-box fallback. |
| `plugin/scripts/` | Deterministic POSIX probes emitting `KEY=val` lines — agents branch on strings, not shell noise. |
| `plugin/bin/launch-mcp.sh` | Claude MCP launcher: finds/downloads `tireless-connect` into `${CLAUDE_PLUGIN_DATA}/bin` (SHA256SUMS-verified), then `exec tireless-connect mcp`. |
| `install.sh` | Multi-client installer for Codex/Cursor (`--codex --cursor --skills-only --all`). Marker-delimited, never duplicates. |
| `agents/AGENTS.snippet.md` | 10-line AGENTS.md degradation of the connect skill. |
| `evals/eval.xml` | Read-only MCP evaluations (mcp-builder format). |

## How it works

- **MCP server (stdio)**: `tireless-connect mcp` exposes exactly twelve
  tools — `tireless_status`, `tireless_login`, `tireless_connect_workspace`,
  `tireless_list_workspaces`, `tireless_get_workspace`,
  `tireless_workspace_action`, `tireless_create_workspace`,
  `tireless_watch_state`, `tireless_share_port`, `tireless_open_editor`,
  `tireless_clipboard_status`, `tireless_doctor`. There is **no exec tool**
  and **no delete anywhere**; `tireless_workspace_action` allows only
  `restart|suspend|resume`.
- **Remote exec is native ssh**: agents run
  `ssh <workspace>.tireless 'cd <dir> && …'` through their own Bash tool, so
  your client's permission system governs every remote command.
- **Auth**: `tireless-connect login` does loopback OAuth (PKCE, public
  client `tireless-connect`, `127.0.0.1:52180-52182`) against the Tireless
  platform, then chains the per-region `tireless login <cpUrl>` in your own
  terminal. Tokens land 0600 in your user config dir under
  `tireless-connect/`.
- **Workspace creation is confirm-gated**: without `{"confirm": true}` the
  create tool only returns the plan/price card; skills forbid agents from
  passing `confirm: true` without your explicit, quoted yes.
- **The Claude plugin is self-contained**: its launcher downloads
  `tireless-connect` from `https://app.tirelesscode.com/connect/bin/<os>-<arch>`
  on first session and keeps it current against `GET /api/agent/version`.

## Security notes

- **Pre-approved (no prompt) while a skill is active**: only narrow reads —
  `tireless list`, `tireless ping`, `tireless users show`,
  `tireless version`, `tireless-clip status`, and the bundled read-only probe
  scripts (`tireless-preflight`, `tireless-verify`, `tireless-urls`,
  `tireless-clip-doctor`).
- **Prompt-gated (your client asks)**: installers (`curl … | sh`), logins,
  `tireless config-ssh`, `tireless-clip setup`, and **every** `ssh` command.
- **Tokens never transit the chat**: logins happen in your own terminal; the
  skills instruct agents to never request, echo, or log tokens.
- **Server-side limits don't trust the agent**: agent-scoped tokens get
  `403 {"error":"agent_scope"}` on workspace deletion, all billing, and all
  admin routes. Lifecycle mutations via the Coder API are forbidden and
  reverted by the platform reconciler (`plugin/reference/lifecycle.md`).
- Caveat, stated rather than hidden: Bash permission globs are coarse — an
  allow rule like `Bash(ssh *.tireless *)` covers any remote command. Keep
  destructive patterns in your own deny rules; this plugin never ships or
  self-authors permission rules.

## Development

```
tireless-agent/
├── .claude-plugin/marketplace.json   # this repo IS the marketplace ("tireless")
├── plugin/                           # the Claude Code plugin
│   ├── .claude-plugin/plugin.json
│   ├── .mcp.json                     # → bin/launch-mcp.sh (stdio)
│   ├── bin/                          # launcher + PATH-visible script wrappers
│   ├── skills/{connect,fix,workspace,clipboard}/SKILL.md
│   ├── scripts/                      # POSIX sh, KEY=val output, shellcheck-clean
│   └── reference/{remote-exec,lifecycle}.md
├── install.sh                        # Codex/Cursor installer
├── agents/AGENTS.snippet.md
└── evals/eval.xml
```

- Lint: `sh -n plugin/scripts/*.sh plugin/bin/* install.sh` and
  `shellcheck` the same set.
- Validate JSON: `python3 -m json.tool < <file>`.
- Try the plugin locally: `claude --plugin-dir ./plugin`.
- Evals follow the anthropics mcp-builder format; run them against
  `tireless-connect mcp` with the mcp-builder evaluation harness.
- The `tireless-connect` binary itself is built and published from the
  platform repo (S3 `connect/<version>/`, stable redirect at
  `/connect/bin/<os>-<arch>`); this repo only launches and instructs it.

## License

MIT — copyright (c) 2026 Nordlytica / Tireless Code. See [LICENSE](LICENSE).
