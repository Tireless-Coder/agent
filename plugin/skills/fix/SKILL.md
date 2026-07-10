---
name: fix
description: Diagnose and repair a broken Tireless connection. Use when ssh <workspace>.tireless fails or hangs, the tireless CLI errors or reports unauthenticated/401, tireless_* MCP tools return errors, clipboard paste into agents on the workspace stops working, or the user says their Tireless workspace, connection, or paste is broken. Walks a deterministic doctor decision tree; every dead end produces a copy-paste support summary.
allowed-tools: Bash(tireless-preflight*), Bash(tireless-verify*), Bash(tireless-clip-doctor*), Bash(tireless list*), Bash(tireless ping*), Bash(tireless version*), Bash(tireless-clip status*)
---

# Fix a broken Tireless connection

Never free-style repairs. Diagnose first, apply the ONE mapped fix, re-run
the diagnosis, repeat. The same ground rules as the connect skill apply:
tokens never in chat, logins in the user's own terminal, no lifecycle
mutations via CLI or Coder API.

## Step 1 — diagnose

**Preferred**: call the `tireless_doctor` MCP tool. It returns
`{"checks": [{"id", "ok", "code", "detail", "fix"}], "summary"}` — walk the
checks in order and fix the FIRST failing one only, then re-run.

**Fallback** (no MCP tools): run `tireless-preflight`
(Codex/Cursor: `sh ~/.agents/skills/tireless/scripts/preflight.sh`), then
layer deeper only where it points:

1. `CLI=missing` → treat as E_BIN_STALE for the CLI: re-run the installer.
2. `AUTH=missing` → separate network from auth:
   `curl -sS -o /dev/null -w '%{http_code}' https://app.tirelesscode.com/api/regions`
   — only a curl TRANSPORT error (non-zero exit, no HTTP code) →
   E_NET_PLATFORM; ANY HTTP status → E_CODER_LOGIN. Do not use `-f`: the
   route requires a session, so a healthy network answers 401 here — an HTTP
   status of any kind proves the platform is reachable.
3. `SSHCFG=missing` → E_SSH_BLOCK.
4. `CLIP` not ok → run `tireless-clip-doctor [workspace]` → E_CLIP_INCLUDE /
   E_CLIP_DEAD per its keys.
5. ssh problems with everything above ok → `tireless ping <workspace>`
   (distinguishes CP-unreachable from workspace-agent-down), then
   `tireless-verify <workspace>` and read `DETAIL`.
6. Workspace state problems → dashboard (fallback) or
   `tireless_get_workspace` (MCP) → E_WS_SUSPENDED / E_WS_ERROR /
   E_HEARTBEAT_STALE.

## Step 2 — fix-code map (exact actions, nothing else)

| Code | Meaning | Fix |
|---|---|---|
| `E_BIN_STALE` | `tireless-connect` older than the platform minimum | Codex/Cursor: `curl -fsSL https://app.tirelesscode.com/connect/install.sh \| sh`. Claude Code: restart the session — the plugin launcher self-updates the binary (or `claude plugin update tireless`). |
| `E_PATH` | `~/.local/bin` not on PATH | Use absolute paths this session; offer to append `export PATH="$HOME/.local/bin:$PATH"` to the shell profile (ask first). |
| `E_NET_PLATFORM` | platform API unreachable | Re-probe `curl -sS -o /dev/null -w '%{http_code}' https://app.tirelesscode.com/api/regions` (any HTTP status — 401 included — means reachable; only a transport error is a network problem); probe general connectivity; ask about VPN/proxy/firewall. Unresolvable → support summary. |
| `E_TOKEN_INVALID` | platform bearer token rejected | User runs `tireless-connect login` in their OWN terminal, replies "done"; re-run doctor. |
| `E_TOKEN_EXPIRED` | token expired and refresh failed | Same fix as E_TOKEN_INVALID. |
| `E_CODER_LOGIN` | Coder CLI session missing/expired for a cell | User runs `tireless-connect login` in their OWN terminal — it opens the region's Coder sign-in automatically (no button to click); they paste the token it shows THERE, never in chat, reply "done"; re-run doctor. (Raw-CLI fallback: `tireless login <cpUrl>`.) |
| `E_SSH_BLOCK` | managed ssh block missing | `tireless config-ssh --yes` |
| `E_CLIP_INCLUDE` | clip include markers missing from ~/.ssh/config | `tireless-clip setup` |
| `E_CLIP_DEAD` | local clipboard daemon not answering | `tireless-clip ensure-daemon`, then reconnect the ssh session (the daemon rides an ssh RemoteForward). |
| `E_WS_SUSPENDED` | workspace suspended | MCP: `tireless_workspace_action` `{"action":"resume"}` then `tireless_watch_state` until ready. No MCP: dashboard. Never `tireless start`. |
| `E_WS_ERROR` | workspace in error state | Do NOT attempt CLI/Coder mutations. Send the user to the dashboard workspace page and emit the support summary. |
| `E_HEARTBEAT_STALE` | workspace agent heartbeat stale | MCP: `tireless_workspace_action` `{"action":"restart"}` then `tireless_watch_state`. Still stale after restart → dashboard escalation + support summary. |

## Step 3 — verify the repair

Re-run the diagnosis (`tireless_doctor` or preflight), then
`tireless-verify <workspace>`. Only report fixed when `VERIFY=ok`.

## Dead ends — support summary

When a fix code has no mapped fix left (or the same code fails twice), stop
and give the user this copy-paste block for support@tirelesscode.com:

```
Tireless support summary
------------------------
date:        <ISO timestamp>
os/arch:     <uname -s / uname -m>
preflight:   <full KEY=val output>
doctor:      <tireless_doctor summary or failing code>
cli version: <tireless version, first line>
verify:      <VERIFY/SSH_EXIT/DETAIL lines>
tried:       <fixes applied, in order>
```

Never include tokens, cookies, or ssh key material in the summary.
