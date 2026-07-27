#!/bin/sh
# ssh-clean.sh [--dry-run] — remove the DEAD stock-Coder block that an old
# `tireless config-ssh` run left in ~/.ssh/config (what preflight reports as
# SSHCFG_STALE=yes).
#
# The block routes nothing: its ProxyCommand points at the stock coderv2
# global-config world, which no supported Tireless setup has ever written.
# It is harmless, but it is also the reason every preflight ends with a
# caveat, so cleaning it up is worth one prompt.
#
# SAFETY (see sshscan.sh for the full argument): a block is only ever removed
# when every executable it proxies through is the Tireless CLI. A real Coder
# deployment's block — proxying through `coder` — is reported and left exactly
# where it is. The file is copied to a timestamped 0600 backup before any
# rewrite, and a config with nothing to clean is not touched at all.
#
# Output is KEY=val; the FIRST line is CLEAN=.
#
#   CLEAN=ok|none|skipped|fail
#   FOUND=<n>            stock-Coder blocks seen
#   REMOVED=<n>          blocks actually removed (0 in --dry-run)
#   LINES=<a-b,...>      line ranges of the removable blocks, BEFORE removal
#   BACKUP=<path|none>   pre-change copy
#   CONFIG=<path>        the file inspected (symlinks resolved)
#   KEPT=<reason>        why a block was left alone (repeatable)
#   DETAIL=<one line>    failure detail
set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
. "$SCRIPT_DIR/alias.sh"
. "$SCRIPT_DIR/sshscan.sh"

DRY=0
case "${1:-}" in
  --dry-run) DRY=1 ;;
  "") ;;
  *) echo "usage: ssh-clean.sh [--dry-run]" >&2; exit 2 ;;
esac

TS="$(date -u +%Y%m%dT%H%M%SZ)"
# Hard-coded, never an argument. The live regional fragments carry the very
# same START-CODER markers (see the scope warning in sshscan.sh), so the only
# way to guarantee this never eats a working ProxyCommand is to give the
# caller no way to point it anywhere else.
CONFIG="$(tireless_resolve_symlink "$HOME/.ssh/config")"

if [ ! -f "$CONFIG" ]; then
  echo "CLEAN=none"
  echo "FOUND=0"
  echo "REMOVED=0"
  echo "CONFIG=$CONFIG"
  exit 0
fi

SCAN="$(tireless_scan_stale_ssh "$CONFIG")"
if [ -z "$SCAN" ]; then
  echo "CLEAN=none"
  echo "FOUND=0"
  echo "REMOVED=0"
  echo "CONFIG=$CONFIG"
  exit 0
fi

FOUND=0
RANGES=""
KEPT=""
# Ranges are collected front-to-back for the report and applied back-to-front
# below, so earlier line numbers stay valid while the file shrinks.
OLDIFS=$IFS; IFS='
'
for row in $SCAN; do
  FOUND=$((FOUND + 1))
  start="$(printf '%s\n' "$row" | awk '{print $2}')"
  end="$(printf '%s\n' "$row" | awk '{print $3}')"
  ours="$(printf '%s\n' "$row" | awk '{print $4}')"
  reason="$(printf '%s\n' "$row" | cut -d' ' -f5-)"
  if [ "$ours" = yes ] && [ "$end" != 0 ]; then
    RANGES="${RANGES:+$RANGES
}$start $end"
  else
    KEPT="${KEPT:+$KEPT
}$reason"
  fi
done
IFS=$OLDIFS

echo_kept() {
  if [ -n "$KEPT" ]; then
    OLDIFS=$IFS; IFS='
'
    for k in $KEPT; do echo "KEPT=$k"; done
    IFS=$OLDIFS
  fi
}

if [ -z "$RANGES" ]; then
  echo "CLEAN=skipped"
  echo "FOUND=$FOUND"
  echo "REMOVED=0"
  echo "CONFIG=$CONFIG"
  echo_kept
  exit 0
fi

pretty_ranges() {
  OLDIFS=$IFS; IFS='
'
  acc=""
  for r in $RANGES; do
    s="${r% *}"; e="${r#* }"
    acc="${acc:+$acc,}$s-$e"
  done
  IFS=$OLDIFS
  printf '%s' "$acc"
}

if [ "$DRY" = 1 ]; then
  echo "CLEAN=ok"
  echo "FOUND=$FOUND"
  echo "REMOVED=0"
  echo "LINES=$(pretty_ranges)"
  echo "BACKUP=none"
  echo "CONFIG=$CONFIG"
  echo_kept
  exit 0
fi

BACKUP="$CONFIG.tireless-backup-$TS"
# Create the backup with the right mode BEFORE any content lands in it: a
# world-readable moment on an ssh config is not acceptable, however brief.
( umask 077; : >"$BACKUP" ) || { echo "CLEAN=fail"; echo "DETAIL=could not create $BACKUP"; exit 1; }
cat "$CONFIG" >"$BACKUP" || { echo "CLEAN=fail"; echo "DETAIL=could not back up $CONFIG"; exit 1; }

TMP="$CONFIG.tireless-tmp-$$"
( umask 077; : >"$TMP" ) || { echo "CLEAN=fail"; echo "DETAIL=could not create a temp file next to $CONFIG"; exit 1; }
trap 'rm -f "$TMP"' EXIT

# Single awk pass: drop every line inside a removable range. Deleting by line
# number (rather than re-matching markers) keeps this identical to what the
# scan reported and to what LINES= told the user.
RANGE_ARG="$(printf '%s' "$RANGES" | tr '\n' ';')"
awk -v ranges="$RANGE_ARG" '
  BEGIN {
    n = split(ranges, parts, ";")
    for (i = 1; i <= n; i++) {
      if (parts[i] == "") continue
      split(parts[i], se, " ")
      lo[i] = se[1] + 0; hi[i] = se[2] + 0
    }
    nr = n
  }
  {
    drop = 0
    for (i = 1; i <= nr; i++) if (lo[i] && NR >= lo[i] && NR <= hi[i]) { drop = 1; break }
    if (!drop) print
  }
' "$CONFIG" >"$TMP" || { echo "CLEAN=fail"; echo "DETAIL=could not rewrite $CONFIG"; exit 1; }

# Never install an empty result over a non-empty config — a truncated ssh
# config would lock the user out of every host they have.
if [ ! -s "$TMP" ] && [ -s "$CONFIG" ]; then
  echo "CLEAN=fail"
  echo "DETAIL=the rewrite came out empty — nothing was changed (backup: $BACKUP)"
  exit 1
fi

cat "$TMP" >"$CONFIG" || { echo "CLEAN=fail"; echo "DETAIL=could not write $CONFIG (backup: $BACKUP)"; exit 1; }
chmod 600 "$CONFIG" 2>/dev/null || true

REMOVED="$(printf '%s\n' "$RANGES" | grep -c .)"
echo "CLEAN=ok"
echo "FOUND=$FOUND"
echo "REMOVED=$REMOVED"
echo "LINES=$(pretty_ranges)"
echo "BACKUP=$BACKUP"
echo "CONFIG=$CONFIG"
echo_kept
