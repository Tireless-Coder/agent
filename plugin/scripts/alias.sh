# shellcheck shell=sh
# alias.sh — sourced helpers shared by the tireless scripts: where the two
# supported setups actually keep state, and how to turn a bare workspace name
# into an ssh alias that resolves TODAY.
#
# Ground truth (verified against the platform installer route.ts and
# tireless-connect setup.go): neither setup writes Host entries into
# ~/.ssh/config directly. Both write marker-wrapped Include blocks there
# pointing at per-region fragment files whose Host patterns end in
# `.<region>.tireless`:
#   installer:  ~/.config/tireless/ssh/<region>.config
#               (markers: # ------------START-TIRELESS-CELLS------------)
#   connector:  <UserConfigDir>/tireless-connect/ssh/<region>.config
#               (markers: # >>> tireless-connect managed regional SSH include >>>)
# Coder sessions live per region next to them, under <root>/coder/<region>.
# The bare `<ws>.tireless` alias is a legacy single-region shape — keep it as
# the LAST fallback only.

# Every state root that may exist on this machine, one per line (paths can
# contain spaces — iterate with `while read`, never `for`).
tireless_state_roots() {
  printf '%s\n' "$HOME/.config/tireless"
  if [ "$(uname 2>/dev/null)" = Darwin ]; then
    printf '%s\n' "$HOME/Library/Application Support/tireless-connect"
  fi
  printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/tireless-connect"
}

# Regional ssh fragment files that exist, one path per line.
tireless_ssh_fragments() {
  tireless_state_roots | while IFS= read -r root; do
    for f in "$root/ssh/"*.config; do
      [ -f "$f" ] && printf '%s\n' "$f"
    done
  done
}

# Distinct host suffixes (e.g. eu-central.tireless) from the fragments'
# `Host *.<suffix>` / `Match host *.<suffix>` lines, one per line.
tireless_ssh_suffixes() {
  tireless_ssh_fragments | while IFS= read -r f; do
    sed -n -e 's/^[[:space:]]*Host[[:space:]]\{1,\}\*\.\([A-Za-z0-9][A-Za-z0-9.-]*tireless\)[[:space:]]*$/\1/p' \
      -e 's/^[[:space:]]*Match[[:space:]]\{1,\}host[[:space:]]\{1,\}\*\.\([A-Za-z0-9][A-Za-z0-9.-]*tireless\).*$/\1/p' "$f"
  done | sort -u
}

# Regional Coder session dirs (each usable as `tireless --global-config DIR`),
# one per line.
tireless_coder_dirs() {
  tireless_state_roots | while IFS= read -r root; do
    for d in "$root/coder/"*/; do
      [ -d "$d" ] && printf '%s\n' "${d%/}"
    done
  done
}

# tireless_resolve_alias <workspace-or-alias> — echo an ssh alias that
# answers, probing candidates with a fast BatchMode ssh. An argument that
# already contains a dot is trusted as a full alias (the connection card's
# ssh_alias). Returns 1 when nothing answers.
tireless_resolve_alias() {
  case "$1" in
    *.*) printf '%s\n' "$1"; return 0 ;;
  esac
  _suffixes="$(tireless_ssh_suffixes)"
  for _sfx in $_suffixes tireless; do
    if ssh -o BatchMode=yes -o ConnectTimeout=10 "$1.$_sfx" 'echo TIRELESS_OK' 2>/dev/null | grep -q TIRELESS_OK; then
      printf '%s.%s\n' "$1" "$_sfx"
      return 0
    fi
  done
  return 1
}
