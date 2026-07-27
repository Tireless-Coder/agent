# Shipping plugin 0.5.0 + connector 0.5.0

Three self-repair capabilities landed together (headless Coder-session
re-mint, dead stock-Coder ssh-block removal, automatic project workspace
stanza). They ship through **three separate channels** and the order matters,
because the plugin's skills now name commands that only a new connector has.

## 0. Before anything

```sh
cd tireless-agent
sh -n plugin/scripts/*.sh plugin/bin/tireless-* install.sh
shellcheck -s sh -e SC1091,SC2016 plugin/scripts/*.sh plugin/bin/tireless-*
python3 -m json.tool < plugin/.claude-plugin/plugin.json >/dev/null
python3 -c "import xml.dom.minidom;xml.dom.minidom.parse('evals/eval.xml')"

cd ../timeless-platform/agent
go build ./... && go vet ./... && go test ./...
```

## 1. Connector binary (platform repo) — do this FIRST

`tireless-connect` 0.5.0 adds the `ensure-session` subcommand, the
`E_SSH_STALE` doctor check, and `setup --keep-stale-ssh`. The plugin's shell
wrapper falls back to `doctor` on older binaries, so nothing BREAKS without
this — but `session-heal` only reports `SESSION=healed` on a connector that
can actually re-mint (0.4.3+, the doctor self-heal), and the fast path needs
0.5.0.

Per the existing recipe: branch → run `connect-publish.yml` → verify the
bucket has `connect/0.5.0/` plus a matching signed `SHA256SUMS` → merge to
`main`. Setting the manifest `min` to 0.5.0 force-upgrades every client; only
do that if you want the fast path guaranteed everywhere, since the fallback
already works.

## 2. Plugin repo (Claude Code users)

Commit and push `tireless-agent`. `plugin/.claude-plugin/plugin.json` is
already at **0.5.0** — the bump is what makes existing installs re-fetch
rather than serving the cached 0.4.2 tree.

New files that must be in the commit (they are new, so easy to miss in a
partial `git add`):

```
plugin/scripts/session-heal.sh   plugin/bin/tireless-session-heal
plugin/scripts/ssh-clean.sh      plugin/bin/tireless-ssh-clean
plugin/scripts/project-note.sh   plugin/bin/tireless-project-note
plugin/scripts/sshscan.sh        (sourced helper, no wrapper)
```

All four scripts and all three wrappers need mode 0755.

## 3. Codex / Cursor users — TWO pins to bump

Neither pin updates itself, and both currently point at trees without this
work.

**a. `install.sh:25`** — `RELEASE_COMMIT` is pinned to `6a8081c`, which is
older than `3afe4f6` (the commit that added `plugin/share/release-pub.pem`).
Anyone running this repo's `install.sh` directly from GitHub *without*
`--skills-only` therefore hits the "release public key missing → refusing the
downloaded binary" branch and gets nothing. Re-pin it to the commit that
carries this release.

**b. `timeless-platform/apps/web/src/app/connect/install.sh/route.ts:25-26`** —
`AGENT_INSTALL_COMMIT` + `AGENT_SOURCE_TARGZ_SHA256`. This is the pin behind
the documented `curl -fsSL https://app.tirelesscode.com/connect/install.sh | sh`
command, and it currently points at `3afe4f6`. Until it moves, Codex and
Cursor users keep receiving the OLD skills and scripts — the platform web app
must be redeployed after the bump.

```sh
# after pushing tireless-agent, with <sha> = the new release commit
curl -fsSL "https://codeload.github.com/Tireless-Coder/agent/tar.gz/<sha>" | shasum -a 256
```

## 4. Smoke test (10 minutes, on a machine with a real workspace)

```sh
tireless-connect ensure-session            # expect SESSION=ok, exit 0
tireless-preflight                         # expect AUTH=ok
tireless-ssh-clean --dry-run               # expect CLEAN=ok/none + LINES=
```

Then force the interesting path — overwrite the regional session token with
junk (`~/.config/tireless/coder/<region>/session`, or the connector's
Application Support equivalent) and confirm:

- `tireless-preflight` → `AUTH=expired` (**not** `missing`)
- `tireless-verify <ws>` → `CAUSE=session_expired` with a `NEXT=` line
- `tireless-session-heal` → `SESSION=healed VIA=ensure-session`
- `tireless-preflight` → `AUTH=ok` again

(All four were live-verified on 2026-07-27 against eu-central.)

Finally, on a scratch repo: `tireless-handoff-sync <ws>` → expect
`PROJECT_NOTE=written` and a marker-wrapped stanza in its `CLAUDE.md`.

## 5. What the adversarial review caught (already fixed — do not reintroduce)

A 35-agent review over this diff confirmed 25 defects, all repaired. Three are
worth remembering because they are easy to write again:

- **An orphan `START-CODER` marker adopted a LATER block's `END`.** Both
  scanners paired the first END after a START with no check for an
  intervening START, so an unterminated block and the next real one merged
  into a single "removable" span — and everything between them (the user's
  own `Host` entries) was deleted. Reproduced end to end in both the shell
  and Go paths; the Go one additionally panicked or spliced the config
  mid-line, because back-to-front removal used offsets from the original
  string against a progressively shortened one. Fixed in `sshscan.sh`,
  `sshstale.go`, with regression tests both sides.
- **The project-note stripper matched the marker as a SUBSTRING**, so a file
  that merely *quoted* `<!-- >>> tireless workspace >>> -->` in prose — as
  this repo's own `reference/handoff.md` now does — started the deletion at
  that sentence and ran to the real end marker. Now a whole-line match.
- **`tireless-handoff-check` is pre-approved because it is read-only**, and
  the first cut of the inline heal ran before the `--check` branch, so that
  command minted a credential and rewrote `~/.ssh/config` with no prompt.
  The heal is now gated on pull mode; check mode reports the expiry and lets
  the caller run the prompt-gated heal deliberately. Verified: after a check
  against an expired session, the session is still expired.

`tireless_doctor` also lost `readOnlyHint: true` — it mints a session as part
of diagnosing, so claiming otherwise misled the host's permission layer.

## 6. Known follow-ups, deliberately not in this release

- The REMOTE discovery-note writer (`handoff-sync.sh`, the
  `>>> timeless handoff briefs >>>` block on the workspace's
  `~/.claude/CLAUDE.md`) is still append-only with a grep guard. It has the
  same rot the local note now avoids, but fixing it means an awk round-trip
  over ssh.
- `Bash(tireless list*)` is pre-approved in all six skills, but a bare
  `tireless list` reads the stock coderv2 config dir that no supported setup
  writes — it fails on a correctly-configured machine. Worth dropping, but it
  touches six files and changes agent behaviour beyond this change's scope.
- There is still no CI. A `shellcheck -s sh` job plus a guard asserting
  `RELEASE_COMMIT` is an ancestor of HEAD *and* contains
  `plugin/share/release-pub.pem` would have caught the stale pin in §3a.
