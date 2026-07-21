# Tireless Agent Connector

Connect AI coding agents — Claude Code, Codex, Cursor — to your
[Tireless](https://tirelesscode.com) cloud dev computer. Install one thing,
then tell your agent **"connect to my workspace"**: it installs the
`tireless` CLI and clipboard companion, authenticates, writes your SSH
config, verifies the connection, and from then on runs commands on your
workspace, connects Claude Code to it or opens VS Code in the right remote
project, shares preview ports, fixes clipboard paste, hands a session off to
continue autonomously on the workspace, and diagnoses its own failures.

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
| `plugin/skills/workspace` | Remote-exec idioms (`ssh <ws>.tireless 'cd … && …'`), editor deeplinks, preview ports, health/metrics, game port + exposure overview, lifecycle guardrails. |
| `plugin/skills/marketplace` | Read-only marketplace browsing (renting stays on the dashboard), installable-tools catalog, installs with once-only revealed secrets, install status. |
| `plugin/skills/clipboard` | Ctrl+V paste bridge verification and repair, drop-box fallback. |
| `plugin/skills/continue` | "Continue this on my workspace": one-command git-over-ssh sync (branch + uncommitted work + env files), handoff brief at `~/.timeless/handoffs/`, autonomous tmux launch steerable from claude.ai. |
| `plugin/scripts/` | Deterministic POSIX probes emitting `KEY=val` lines — agents branch on strings, not shell noise. |
| `plugin/bin/launch-mcp.sh` | Claude MCP launcher: finds/downloads `tireless-connect` into `${CLAUDE_PLUGIN_DATA}/bin` (signature-verified against the pinned release key in `plugin/share/`, then hash-checked against the signed SHA256SUMS), then `exec tireless-connect mcp`. |
| `install.sh` | Multi-client installer for Codex/Cursor (`--codex --cursor --skills-only --all`). Marker-delimited, never duplicates. |
| `agents/AGENTS.snippet.md` | Compact AGENTS.md degradation of the skills. |
| `evals/eval.xml` | Read-only MCP evaluations (mcp-builder format). |

## How it works

- **MCP server (stdio)**: `tireless-connect mcp` exposes exactly twenty
  tools. Connection & repair: `tireless_status`, `tireless_login`,
  `tireless_connect_workspace`, `tireless_doctor`. Workspaces:
  `tireless_list_workspaces`, `tireless_get_workspace`,
  `tireless_workspace_action`, `tireless_create_workspace`,
  `tireless_watch_state`, `tireless_workspace_health`. Surfaces:
  `tireless_share_port`, `tireless_open_editor`, `tireless_clipboard_status`,
  `tireless_game_port`, `tireless_exposure_overview`. Marketplace & installs:
  `tireless_marketplace_browse`, `tireless_marketplace_listing`,
  `tireless_recipes_catalog`, `tireless_install_app`,
  `tireless_install_status`. There is **no exec tool**, **no delete
  anywhere**, and **no purchase tool** — renting marketplace hardware is
  dashboard-only; `tireless_workspace_action` allows only
  `restart|suspend|resume`.
- **Remote exec is native ssh**: agents run
  `ssh <workspace>.tireless 'cd <dir> && …'` through their own Bash tool, so
  your client's permission system governs every remote command.
- **Connect, then open**: `tireless_open_editor` launches VS Code/Cursor over
  Remote-SSH into `/home/dev/<workspace>`, or starts a fresh local Claude Code
  session with a visible, prefilled Tireless connection request. Claude Code
  deep links require v2.1.91+ and the user still presses Enter before the
  request is sent. If the Tireless plugin is not installed in that Claude
  client, the prompt falls back to the already-configured native SSH alias.
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
  Every download must verify: the SHA256SUMS manifest carries a detached
  ECDSA signature made with the platform's offline release key, and the
  launcher checks it against the public key pinned in the plugin
  (`plugin/share/release-pub.pem`, installed from this repo) before hashing
  the binary — so the download origin alone cannot push executable code, and
  an unverifiable download never runs (fail closed).

**Prefer plain HTTP?** The dashboard's API page
(`https://app.tirelesscode.com/dashboard/api`) mints personal API keys that
hit the same API with the same permissions as the connector — handy for
scripts and CI. Docs: <https://tirelesscode.com/docs/api>. The connector
itself keeps using its OAuth login; that stays the primary path for agents.

## Security notes

- **Pre-approved (no prompt) while a skill is active**: only narrow reads —
  `tireless list`, `tireless ping`, `tireless users show`,
  `tireless version`, `tireless-clip status`, and the bundled read-only probe
  scripts (`tireless-preflight`, `tireless-verify`, `tireless-urls`,
  `tireless-clip-doctor`, `tireless-handoff-state`).
- **Prompt-gated (your client asks)**: installers (`curl … | sh`), logins,
  `tireless config-ssh`, `tireless-clip setup`, the handoff mutations
  (`tireless-handoff-sync`, `tireless-handoff-launch` — they write to your
  workspace and start an agent on it), and **every** `ssh` command.
- **Tokens never transit the chat**: logins happen in your own terminal; the
  skills instruct agents to never request, echo, or log tokens.
- **Binary supply chain is signature-gated**: `tireless-connect` downloads
  (plugin launcher and `install.sh`) only execute after the SHA256SUMS
  manifest verifies against the ECDSA release public key pinned in this repo
  and the binary hash matches the signed manifest. The signing key stays
  offline; a compromised download origin or bucket cannot push code by
  itself.
- **Hand-back never writes outside the repo**: `tireless-handoff-pull`
  extracts workspace archives into a scratch dir and validates every path —
  and every destination directory, symlinks included — before copying, so a
  hostile or compromised workspace cannot escape the repo through the tar or
  a planted symlink.
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
│   ├── share/release-pub.pem         # pinned release-signing public key (offline key pair)
│   ├── skills/{connect,fix,workspace,marketplace,clipboard,continue}/SKILL.md
│   ├── scripts/                      # POSIX sh, KEY=val output, shellcheck-clean
│   └── reference/{remote-exec,lifecycle,handoff}.md
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
