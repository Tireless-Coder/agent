---
name: fix
description: Diagnose and repair a broken Tireless connection. Use when ssh <workspace>.tireless fails or hangs, the tireless CLI errors or reports unauthenticated/401, tireless_* MCP tools return errors, clipboard paste into agents on the workspace stops working, or the user says their Tireless workspace, connection, or paste is broken. Walks a deterministic doctor decision tree; every dead end produces a copy-paste support summary.
allowed-tools: Bash(tireless-preflight*), Bash(tireless-verify*), Bash(tireless-clip-doctor*), Bash(tireless list*), Bash(tireless ping*), Bash(tireless version*), Bash(tireless-clip status*)
---

# Fix a broken Tireless connection

Never free-style repairs. Diagnose first, apply the ONE mapped fix, re-run
the diagnosis, repeat. The same ground rules as the connect skill apply:
tokens never in chat, platform sign-ins (browser) belong in the user's own
terminal, no lifecycle mutations via CLI or Coder API. A routine per-cell
Coder session re-mint is NOT an interactive login — see `E_CODER_LOGIN`.

## Step 1 — diagnose

**Preferred**: call the `tireless_doctor` MCP tool. It returns
`{"checks": [{"id", "ok", "code", "detail", "fix"}], "summary"}` — walk the
checks in order and fix the FIRST failing one only, then re-run.

**Fallback** (no MCP tools): run `tireless-preflight`
(Codex/Cursor: `sh ~/.agents/skills/tireless/scripts/preflight.sh`), then
layer deeper only where it points. The repair commands named below —
`tireless-session-heal`, `tireless-ssh-clean` — are Claude Code PATH
wrappers; on Codex/Cursor use `sh ~/.agents/skills/tireless/scripts/session-heal.sh`
and `sh ~/.agents/skills/tireless/scripts/ssh-clean.sh`.

1. `CLI=missing` → treat as E_BIN_STALE for the CLI: re-run the installer.
2. `AUTH=expired` → **do not diagnose further and do not ask the user
   anything.** This is the routine 8h session expiry. Run
   `tireless-session-heal` (headless server-mint: no browser, no paste, no
   token in chat) and branch on its FIRST line:
   - `SESSION=healed` / `SESSION=ok` → re-run the preflight and carry on.
   - `SESSION=action_required` → a human is needed; follow its `NEXT=`.
   - `SESSION=fail` → **run it at most once more, never in a loop.** Read
     `CODE=`: `E_EDGE_BLOCK` → the fix map's edge-block row (no client-side
     fix, do not retry); `E_NET_PLATFORM` → network first; anything else →
     go straight to the support summary. Re-running the preflight here just
     returns you to this step, so treat a second `SESSION=fail` as a dead
     end, not an instruction to try again.
3. `AUTH=error` → the probe failed for a NON-auth reason. Do NOT heal; treat
   as E_NET_PLATFORM and check the network first.
4. `AUTH=missing` → nothing was ever set up here. Separate network from auth:
   `curl -sS -o /dev/null -w '%{http_code}' https://app.tirelesscode.com/api/regions`
   — only a curl TRANSPORT error (non-zero exit, no HTTP code) →
   E_NET_PLATFORM; ANY HTTP status → E_CODER_LOGIN. Do not use `-f`: the
   route requires a session, so a healthy network answers 401 here — an HTTP
   status of any kind proves the platform is reachable.
6. `SSHCFG=missing` → E_SSH_BLOCK.
7. `SSHCFG_STALE=yes` → see the fix map; never a blocker on its own.
8. `CLIP` not ok → run `tireless-clip-doctor [workspace]` → E_CLIP_INCLUDE /
   E_CLIP_DEAD per its keys.
9. ssh problems with everything above ok → `tireless ping <workspace>`
   (distinguishes CP-unreachable from workspace-agent-down), then
   `tireless-verify <workspace>` and read `CAUSE` first — `CAUSE=session_expired`
   is the same routine expiry as `AUTH=expired` above, not a broken
   connection; heal and re-verify instead of walking this tree further.
10. Workspace state problems → dashboard (fallback) or
    `tireless_get_workspace` (MCP) → E_WS_SUSPENDED / E_WS_ERROR /
    E_HEARTBEAT_STALE.

## Step 2 — fix-code map (exact actions, nothing else)

| Code | Meaning | Fix |
|---|---|---|
| `E_BIN_STALE` | `tireless-connect` older than the platform minimum | Codex/Cursor: `curl -fsSL https://app.tirelesscode.com/connect/install.sh \| sh`. Claude Code: restart the session — the plugin launcher self-updates the binary (or `claude plugin update tireless`). |
| `E_PATH` | `~/.local/bin` not on PATH | Use absolute paths this session; offer to append `export PATH="$HOME/.local/bin:$PATH"` to the shell profile (ask first). |
| `E_NET_PLATFORM` | platform API unreachable | Re-probe `curl -sS -o /dev/null -w '%{http_code}' https://app.tirelesscode.com/api/regions` (any HTTP status — 401 included — means reachable; only a transport error is a network problem); probe general connectivity; ask about VPN/proxy/firewall. Unresolvable → support summary. |
| `E_EDGE_BLOCK` | the platform's edge (Cloudflare bot protection) is blocking API traffic | This is NOT a login problem — do NOT loop `tireless-connect login` (unlike E_TOKEN_INVALID, the request never reaches auth). No client-side fix exists: the platform operator must exempt `/api/*` from bot protection. Tell the user exactly that and emit the support summary. |
| `E_TOKEN_INVALID` | platform bearer token rejected | User runs `tireless-connect login` in their OWN terminal, replies "done"; re-run doctor. |
| `E_TOKEN_EXPIRED` | token expired and refresh failed | Same fix as E_TOKEN_INVALID. |
| `E_CODER_LOGIN` | Coder CLI session missing/expired for a cell | Routine expiry (cells cap sessions at 8h — expect this overnight), NOT a re-onboarding. Run `tireless-session-heal` (or, with MCP, call `tireless_doctor` — it re-mints as part of diagnosing). Both are headless: server-minted, no browser, no paste, no token in chat. Never run `tireless-connect login` from your own Bash tool as the heal: when the platform token is ALSO dead it opens a browser and blocks on the loopback callback, which hangs your session. Only when the heal reports `SESSION=action_required` does the user run `tireless-connect login` in their OWN terminal and reply "done". Then re-run doctor. |
| `E_SSH_BLOCK` | managed ssh block missing | `tireless-connect setup` (writes the marker-wrapped Include + regional fragments — the worlds preflight actually checks). Never bare `tireless config-ssh --yes`: it targets the stock coderv2 world and writes a block nothing uses. |
| `E_SSH_STALE` / `SSHCFG_STALE=yes` | leftover stock-Coder block in `~/.ssh/config` from an old `tireless config-ssh` run | Only when `SSHCFG_STALE_OURS=yes`: run `tireless-ssh-clean` — it backs the file up (0600, timestamped) and removes only blocks whose every ProxyCommand runs the Tireless CLI. `SSHCFG_STALE_OURS=no` means the block may belong to a real Coder deployment the user runs: report it, never touch it. Preview with `tireless-ssh-clean --dry-run`. Never a blocker — it routes nothing either way. |
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
