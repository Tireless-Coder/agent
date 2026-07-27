#!/bin/sh
# ssh-repair.sh — restore the regional SSH config so `ssh <ws>.<region>.tireless`
# routes through the Tireless proxy again.
#
# The sibling failure to an expired session, and the second one to cost a user
# their access on 2026-07-27. Both look identical from the outside — "my ssh to
# the box stopped working" — and they are completely different faults with
# completely different repairs, which is exactly why an agent left to guess
# picks wrong. Auth expiry is `tireless-session-heal`. This is the other one:
# the ssh config that turns an alias into a connection is missing, stale, or
# shadowed, so OpenSSH never even reaches the proxy.
#
# The three shapes it takes, all of them silent until you try to connect:
#   - the regional fragment is missing or was written for a different Coder
#     world (on connector 0.4.2, `setup` SKIPS any region whose session is
#     dead — so the classic "I re-ran setup and nothing changed" leaves the
#     fragment exactly as stale as it was)
#   - ~/.ssh/config lost the managed Include, so the fragments exist and route
#     nothing
#   - two state roots both define the region and OpenSSH's first-value-wins
#     picks the other one — healing one root then changes nothing visible
#
# Output is KEY=val; the FIRST line is SSHFIX=.
#
#   SSHFIX=ok               every region routes through its own proxy
#   SSHFIX=repaired         a fragment/Include was rewritten — retry the ssh
#   SSHFIX=shadowed         another root wins for a region; NOT auto-fixed
#   SSHFIX=action_required  only the user can fix this — NEXT says how
#   SSHFIX=fail             unexpected breakage — DETAIL says what
#   REGIONS=<region>:<verdict>,…|none
#   DETAIL=<one line>       never contains a token
#   NEXT=<what to do next>
#
# Mutating (it rewrites ssh config files), so an agent reaching for it is
# prompt-gated, exactly like tireless-ssh-clean.
set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
. "$SCRIPT_DIR/alias.sh"

REPAIR_TIMEOUT="${TIRELESS_SSH_REPAIR_TIMEOUT:-90}"

emit() {
  echo "SSHFIX=$1"
  echo "REGIONS=${2:-none}"
  if [ -n "${3:-}" ]; then echo "DETAIL=$3"; fi
  if [ -n "${4:-}" ]; then echo "NEXT=$4"; fi
}

oneline() {
  printf '%s' "$1" | tr '\r\n' '  ' | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//' | cut -c1-400
}

# The connector owns the Include and the fragments, so it is the thing that
# rewrites them. Found the same three ways session-heal.sh finds it.
CONNECT=""
for c in \
  "$(command -v tireless-connect 2>/dev/null || true)" \
  "${CLAUDE_PLUGIN_DATA:-$HOME/.claude/plugins/data/tireless}/bin/tireless-connect" \
  "$HOME/.local/bin/tireless-connect"
do
  if [ -n "$c" ] && [ -x "$c" ]; then CONNECT="$c"; break; fi
done

# region_proxy <region-dir> — the ProxyCommand OpenSSH would actually use for a
# host in that region, or empty. This is the only check that matters: not "is
# there a file" but "does ssh agree". The probe host cannot exist, and `ssh -G`
# never connects — it only resolves configuration.
region_proxy() {
  _region="$(basename "$1")"
  ssh -G "tireless-repair-probe.$_region.tireless" 2>/dev/null | sed -n 's/^proxycommand //p' | head -1
}

# A region is healthy when the ProxyCommand OpenSSH resolves names THIS
# region's own isolated Coder config dir. Naming a DIFFERENT tireless dir is
# the two-root shadowing case, which is a user-config conflict, not our file to
# silently rewrite.
classify_region() {
  _dir="$1"
  _pc="$(region_proxy "$_dir")"
  if [ -z "$_pc" ]; then printf 'broken\n'; return 0; fi
  case "$_pc" in
    *"$_dir"*) printf 'ok\n' ;;
    *tireless*|*coderv2*) printf 'shadowed\n' ;;
    *) printf 'broken\n' ;;
  esac
}

scan() {
  REGIONS=""
  WORST=ok
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    v="$(classify_region "$d")"
    REGIONS="${REGIONS:+$REGIONS,}$(basename "$d"):$v"
    case "$v" in
      shadowed) WORST=shadowed ;;
      broken) [ "$WORST" = shadowed ] || WORST=broken ;;
    esac
  done <<EOF
$(tireless_coder_dirs_unique)
EOF
}

scan
if [ -z "$REGIONS" ]; then
  emit action_required none \
    "this machine has no regional Coder session directories, so there is no ssh config to repair" \
    "run the connect skill (or \`tireless-connect setup\`) to onboard this machine first"
  exit 1
fi
if [ "$WORST" = ok ]; then
  emit ok "$REGIONS" "every region resolves to its own Tireless proxy — the ssh config is NOT what failed" \
    "if ssh still fails, check auth (\`tireless-session-heal\`) and confirm you used the FULL alias <workspace>.<region>.tireless, never the bare <workspace>.tireless"
  exit 0
fi

if [ "$WORST" = shadowed ]; then
  emit shadowed "$REGIONS" \
    "another managed ssh config wins for at least one region (two state roots both define it; OpenSSH takes the FIRST value)" \
    "show the user \`ssh -G <alias> | grep -i proxycommand\` and which Include in ~/.ssh/config comes first; removing the stale root's Include is a user decision, so do not edit it automatically"
  exit 1
fi

if [ -z "$CONNECT" ]; then
  emit action_required "$REGIONS" \
    "the regional ssh config is stale but tireless-connect is not installed here" \
    "install it: curl -fsSL https://app.tirelesscode.com/connect/install.sh | sh (Claude Code: restart the session — the plugin launcher installs it)"
  exit 1
fi

# A dead session makes the repair a no-op on connector 0.4.2 (setup skips any
# region it cannot reach), so heal FIRST and repair second. Ordering matters
# more than it looks: it is the difference between "I re-ran setup and nothing
# changed" and a fixed connection.
heal_out="$(sh "$SCRIPT_DIR/session-heal.sh" 2>&1 || true)"
case "$heal_out" in
  SESSION=action_required*)
    emit action_required "$REGIONS" \
      "the ssh config is stale AND the session needs an interactive sign-in first: $(oneline "$heal_out")" \
      "the USER signs in as that output's NEXT line says, then re-run this"
    exit 1
    ;;
esac

# `setup` is the connector's own owner of these files: it rewrites the
# marker-wrapped Include at byte zero and regenerates every regional fragment
# (and on newer builds prunes a dead stock-Coder block while it is there).
# Bounded and stdin-free — it must never become the thing that hangs a session.
err="$(mktemp "${TMPDIR:-/tmp}/tireless-sshfix.XXXXXX")"
if tireless_run_bounded "$REPAIR_TIMEOUT" "$err" "$CONNECT" setup </dev/null; then
  rc=0
else
  rc=$?
fi
detail="$(oneline "$(cat "$err" 2>/dev/null || true)")"
rm -f "$err"

scan
if [ "$WORST" = ok ]; then
  emit repaired "$REGIONS" "regenerated the managed ssh include and regional fragments" \
    "retry the ssh command — use the FULL alias <workspace>.<region>.tireless"
  exit 0
fi
if [ "$rc" = 124 ]; then
  emit fail "$REGIONS" "\`tireless-connect setup\` did not finish within ${REPAIR_TIMEOUT}s" \
    "re-run once; if it persists, the USER runs \`tireless-connect setup\` in their own terminal"
  exit 1
fi
emit fail "$REGIONS" "${detail:-the ssh config is still stale after regenerating it}" \
  "run the fix skill's E_SSH_BLOCK row; do not retry this blindly"
exit 1
