---
name: clipboard
description: Fix or verify image paste (Ctrl+V) into Claude Code or other agents running on a Tireless workspace. Use when pasting a screenshot into an agent on the workspace does nothing, the user asks why images will not paste over SSH, the clipboard bridge needs setup or repair, or paste needs verification after connecting.
allowed-tools: Bash(tireless-clip-doctor*), Bash(tireless-clip status*), Bash(tireless list*)
---

# Clipboard bridge — paste images into agents on the workspace

The bridge: `tireless-clip` daemon on the user's machine → ssh RemoteForward
(port 19985) → fake `xclip`/`wl-paste` shim on the workspace. When wired,
Ctrl+V in Claude Code on the workspace reads the user's LOCAL clipboard.

## Rule 1 — Ctrl+V, not Cmd+V

On macOS, Cmd+V pastes into the local terminal app; the agent on the
workspace never sees an image, only text. The keystroke the remote agent
understands is **Ctrl+V**. Check this before any repair — it is the most
common "bug".

## Verify behaviorally

Ask the user: "Copy any screenshot to your clipboard (e.g. take one now) and
tell me when done — I'll check it crosses the bridge." Then run:

```
ssh <ws>.tireless 'xclip -selection clipboard -t image/png -o | head -c 8'
```

The first bytes must be the PNG magic (`\x89PNG`). For a clean yes/no, run
`tireless-clip-doctor <ws>` (Codex/Cursor:
`sh ~/.agents/skills/tireless/scripts/clip-doctor.sh <ws>`) and read
`REMOTE_PNG=ok|none|unreachable`. This exercises the real tunnel + shim path
end to end — exactly what Ctrl+V does.

## Repair decision tree

Run `tireless-clip-doctor [<ws>]` (or the `tireless_clipboard_status` MCP
tool) and fix the FIRST failing key:

| Key | Fix |
|---|---|
| `CLIP_BIN=missing` | `curl -fsSL https://tirelesscode.com/clip/install.sh \| sh` (installs AND wires) |
| `CLIP_CONFIG=missing` or `CLIP_INCLUDE=missing` | `tireless-clip setup` |
| `DAEMON=dead` | `tireless-clip ensure-daemon`, then RECONNECT the ssh session (the tunnel is per-connection) |
| `REMOTE_SHIM=missing` | workspace image predates the bridge — user installs the "clipboard-bridge" recipe from the dashboard |
| `REMOTE_SHIM/PNG=unreachable` | connection problem, not clipboard — switch to the fix skill |
| `REMOTE_PNG=none` with all above ok | clipboard empty or holds text/files — bridge carries images only; re-copy an actual image and re-check. Also check `TIRELESS_CLIP_DISABLE` is not set in the remote env |

After any fix, re-run the behavioral verification.

## Drop-box fallback (always works)

The dashboard workspace page has a Paste page ("Clipboard" link, also in the
`links` of `tireless_get_workspace`): the user pastes an image in the
browser, and agents on the workspace read it for the next **5 minutes**
(then it goes stale by design). Offer this when the live bridge cannot be
fixed right now.

- **Windows local machine**: `tireless-clip` does not ship for Windows yet —
  the drop-box page is the ONLY paste path; do not attempt the installer.

Never share ports 6810 (drop-box) or 19985 (tunnel) publicly — they are
reserved, and the tooling refuses.
