# shellcheck shell=sh
# sshscan.sh — sourced helper: find the DEAD stock-Coder block a legacy
# `tireless config-ssh` run left in ~/.ssh/config, and decide whether it is
# provably ours to delete.
#
# Why it exists: the stock Coder CLI writes a marker-delimited section with
# `Host coder.*` / `Host *.coder` whose ProxyCommand points at the STOCK
# coderv2 global-config directory. No supported Tireless setup has ever used
# that world (both the platform installer and `tireless-connect setup` write
# per-region fragments matching `*.<region>.tireless` behind an Include), so
# the block routes nothing — but it sits in the user's ssh config forever and
# keeps `tireless-preflight` reporting SSHCFG_STALE=yes.
#
# The safety rule is deliberately narrow. Somebody may run a REAL Coder
# deployment next to Tireless, and their block looks almost identical.
# We therefore only ever call a block OURS when every executable it proxies
# through is the Tireless-rebranded CLI — nothing but a `tireless config-ssh`
# run can produce that combination.

# tireless_resolve_symlink lives in alias.sh — source that first.

# SCOPE — LOAD-BEARING, READ THIS BEFORE CHANGING ANY CALLER.
# Only ever pass ~/.ssh/config (or its resolved symlink target) to the scan.
# The LIVE regional fragment that `tireless-connect setup` generates
# (~/.config/tireless/ssh/<region>.config, or the connector's equivalent under
# Application Support) carries the SAME START-CODER/END-CODER markers AND its
# own `Host coder.*` stanza — verified on a working machine 2026-07-27. A scan
# pointed at a fragment would classify the WORKING ProxyCommand as litter and
# a prune would delete the user's connectivity. Never pass a path from
# tireless_ssh_fragments here.

# tireless_scan_stale_ssh <file> — print one line per stock-Coder block:
#
#   BLOCK <start-line> <end-line|0> <ours:yes|no> <reason>
#
# end-line 0 means the block has no END marker: reported, never removable —
# guessing where it ends risks eating the user's own Host entries below it.
# Prints nothing when the file is absent or contains no such block.
tireless_scan_stale_ssh() {
  [ -f "$1" ] || return 0
  awk -v cli="tireless" '
    function basename(p,   n, a) { n = split(p, a, "/"); return a[n] }
    # firstword: the executable at the head of a shell command line, honouring
    # a quoted path that contains spaces.
    function firstword(s,   q, i, c, outp) {
      sub(/^[[:blank:]]+/, "", s)
      c = substr(s, 1, 1)
      if (c == "\"" || c == "'"'"'") {
        q = index(substr(s, 2), c)
        if (q == 0) return ""
        return substr(s, 2, q - 1)
      }
      outp = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == " " || c == "\t") break
        outp = outp c
      }
      return outp
    }
    # The executable a ProxyCommand / Match !exec line runs. ssh quotes the
    # WHOLE command after !exec, so that quoted string must be unwrapped
    # before the head word is read — reading it as a path is how
    # `!exec "/…/tireless connect exists %h"` once looked like a foreign
    # binary called "tireless connect exists %h".
    function execword(s,   rest, i, q) {
      sub(/^[[:blank:]]+/, "", s)
      if (s ~ /^ProxyCommand[[:blank:]]/) {
        sub(/^ProxyCommand[[:blank:]]+/, "", s)
        return firstword(s)
      }
      i = index(s, "!exec")
      if (i == 0) return ""
      rest = substr(s, i + 5)
      sub(/^[[:blank:]]+/, "", rest)
      q = substr(rest, 1, 1)
      if (q == "\"" || q == "'"'"'") {
        i = index(substr(rest, 2), q)
        if (i == 0) return ""
        rest = substr(rest, 2, i - 1)
      }
      return firstword(rest)
    }
    { gsub(/\015/, ""); line[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        if (line[i] ~ /^[[:blank:]]*#[[:blank:]]*-+START-CODER-+[[:blank:]]*$/) starts[++ns] = i
        if (line[i] ~ /^[[:blank:]]*#[[:blank:]]*-+END-CODER-+[[:blank:]]*$/) ends[++ne] = i
      }
      for (s = 1; s <= ns; s++) {
        st = starts[s]
        nextst = (s < ns) ? starts[s + 1] : 0
        en = 0
        for (e = 1; e <= ne; e++) {
          if (ends[e] <= st) continue
          # An END only closes THIS start when no other START intervenes.
          # Without that test an unterminated block adopts the next block'"'"'s
          # END and the span between them — the user'"'"'s own Host entries —
          # gets classified as one removable block. That is the exact
          # "eating user Host entries" failure the header warns about, and
          # the missing-END check alone does not catch it, because the END
          # does exist, just not for this start.
          if (nextst > 0 && ends[e] > nextst) en = 0
          else en = ends[e]
          break
        }
        if (en == 0) {
          print "BLOCK " st " 0 no the block has no matching END-CODER marker of its own - refusing to guess where it ends"
          continue
        }
        seen = 0
        foreign = ""
        for (i = st; i <= en; i++) {
          if (line[i] ~ /^[[:blank:]]*ProxyCommand[[:blank:]]/ || line[i] ~ /!exec[[:blank:]]/) {
            w = execword(line[i])
            if (w == "") continue
            seen++
            if (basename(w) != cli) { foreign = basename(w); break }
          }
        }
        if (seen == 0) {
          print "BLOCK " st " " en " no the block runs no ProxyCommand we recognise - leaving it alone"
        } else if (foreign != "") {
          print "BLOCK " st " " en " no the block proxies through " foreign ", not the Tireless CLI - it may belong to a real Coder deployment you use"
        } else {
          print "BLOCK " st " " en " yes dead stock-Coder block from an old tireless config-ssh run"
        }
      }
    }
  ' "$1"
}
