# Remote exec on a Tireless workspace — idioms

Remote work goes through the agent's native Bash tool with plain ssh against
the workspace's ssh alias. There is no MCP exec tool by design: your
client's permission system (allow/deny/ask) governs every remote command
instead of a blanket-approved tool.

## The alias

The connection card's `ssh_alias` (also `ALIAS=` from `tireless-verify`) is
the real name — regional, e.g. `myws.eu-central.tireless`. It is defined in
a per-region fragment (`~/.config/tireless/ssh/*.config` or the
tireless-connect equivalent) that a marker-wrapped Include in `~/.ssh/config`
pulls in; `tireless-connect setup` (or the platform installer) writes both.
It uses a ProxyCommand (no host-key prompts — nothing ever blocks a
non-interactive Bash call on first contact). The bare `myws.tireless` form is
legacy single-region only. Use only the alias; never `ssh dev@<ip>` with
relaxed host-key checking. Examples below write `myws.tireless` for
brevity — substitute your real alias.

## Fresh shell per call — always cd-prefix

Every `ssh host 'cmd'` starts a new login shell in `$HOME`. No working
directory, no environment, no shell state survives between calls. The single
most common agent failure is forgetting this.

```sh
# WRONG — runs in $HOME
ssh myws.tireless 'npm test'

# RIGHT
ssh myws.tireless 'cd ~/project && npm test'
```

## Probes: fail fast, never hang

For connectivity checks and anything that must not block:

```sh
ssh -o BatchMode=yes -o ConnectTimeout=10 myws.tireless 'echo ok'
```

`BatchMode=yes` turns would-be interactive prompts into immediate errors;
`ConnectTimeout` bounds the wait. `tireless ping <ws>` additionally
distinguishes control-plane-unreachable from workspace-agent-down.

## Long jobs (>2 minutes): detach with tmux

Bash tools time out (Claude Code: 2 min default, 10 max). Run long builds,
test suites, and servers detached, then poll:

```sh
ssh myws.tireless 'cd ~/project && tmux new -d -s build "make -j4 2>&1 | tee ~/build.log"'
# poll:
ssh myws.tireless 'tail -20 ~/build.log'
# is it still running?
ssh myws.tireless 'tmux has-session -t build 2>/dev/null && echo RUNNING || echo DONE'
```

## Cap output — protect your context

Remote commands can dump megabytes. Always truncate or filter:

```sh
ssh myws.tireless 'cd ~/project && npm test 2>&1 | tail -100'
ssh myws.tireless 'cd ~/project && grep -n "ERROR" build.log | head -50'
```

## Files — reading and understanding remote code

Your Read/Grep/Glob tools see only the LOCAL filesystem — everything on the
workspace goes through ssh. Prefer running tools remotely over copying files
locally:

```sh
# read a file (always sed/head-bounded, never bare cat on unknown sizes)
ssh myws.tireless 'sed -n 1,120p ~/project/src/main.go'
# search
ssh myws.tireless 'cd ~/project && grep -rn "handleAuth" --include="*.go" . | head -30'
# explore structure
ssh myws.tireless 'cd ~/project && find . -type f -name "*.ts" -not -path "*/node_modules/*" | head -50'
ssh myws.tireless 'cd ~/project && ls -la src/'
```

When you genuinely need files locally (diff against local code, feed to a
local tool), pull them explicitly and put them in a scratch dir:

```sh
scp myws.tireless:project/src/main.go /tmp/ws-main.go          # one file
ssh myws.tireless 'cd ~/project && tar -czf - src' | tar -xzf - -C /tmp/ws-src  # a subtree
```

For edits, prefer git (the handoff commands) or remote editors over
heredocs — quoting bugs in `ssh 'cat > file <<EOF'` waste turns.

Moving a whole working tree (branch + uncommitted changes + env files) onto
the workspace is `tireless-handoff-sync`; bringing the workspace's work back
afterwards is `tireless-handoff-pull` (probe first with the read-only
`tireless-handoff-check`) — one command each, direct git-over-ssh, no GitHub
credentials involved (see `handoff.md`).

## Quoting

Single-quote the whole remote command; inside it, prefer double quotes.
For anything with tricky quoting, write a script to a remote file first or
use `printf %s | ssh host 'cat > …'`.

## What never goes over this channel

- `tireless start|stop|delete|create` or Coder API mutations — see
  `lifecycle.md`.
- Tokens/secrets echoed into chat or logs.
- Anything on reserved ports 22, 13337, 6800, 6801, 6810, 19985 being
  exposed publicly.
