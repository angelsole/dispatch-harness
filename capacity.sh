# shellcheck shell=bash
# Subscription capacity, read off the station's own disk.
#
# Sourced, never executed. Two callers, one accountant:
#   quartermaster.sh  — at 19:00, how many runs fit in what is left tonight
#   run-task.sh       — right now, is there anything left to spend at all
#
# THE HARD RULE, and the reason this is one file instead of two copies: the only
# thing consulted is the station's own Claude logs. ccusage is a local-file
# accountant — it parses the JSONL under CLAUDE_CONFIG_DIR — and `--offline`
# additionally forbids it fetching a pricing table, so "no model provider is
# ever contacted" holds by construction rather than by trust. Nothing in here
# opens a socket, and there is no remote usage API to be tempted by.
#
# Knobs, set by the caller before it calls (each script maps its own env name
# onto these, so the two keep their documented prefixes):
#   CAPACITY_TIMEOUT      seconds allowed for one ccusage read          (120)
#   CAPACITY_TOKEN_LIMIT  pin the block ceiling instead of inferring it (unset)
#
# CAP_* are outputs read by the sourcing script, which shellcheck cannot see.
# shellcheck disable=SC2034

CAPACITY_TIMEOUT="${CAPACITY_TIMEOUT:-120}"
CAPACITY_TOKEN_LIMIT="${CAPACITY_TOKEN_LIMIT:-}"

# A process cap that exists on macOS, where timeout(1) does not.
capacity_capped() { perl -e 'alarm shift; exec @ARGV' "$@"; }

# Read one station's own Claude logs. If the installed ccusage is too old to
# support --offline, capacity falls back honestly instead of weakening the
# network boundary.
capacity_blocks() {  # $1 = the station's claude config dir; prints ccusage JSON
  local out
  command -v npx >/dev/null 2>&1 || return 1
  out=$(CLAUDE_CONFIG_DIR="$1" capacity_capped "$CAPACITY_TIMEOUT" \
    npx -y ccusage@latest blocks --json --offline 2>/dev/null </dev/null) || out=""
  printf '%s' "$out" | jq -e '.blocks' >/dev/null 2>&1 || return 1
  printf '%s' "$out"
}

# ccusage timestamps are ISO 8601, usually UTC. perl is already a hard
# dependency and BSD/GNU date(1) disagree on every flag this would need.
capacity_epoch_of() {  # $1 = ISO 8601 timestamp; prints the epoch, or fails
  [ -n "${1:-}" ] || return 1
  perl -e '
    use strict; use warnings; use Time::Local qw(timegm);
    my $s = $ARGV[0];
    $s =~ /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(Z|[+-]\d{2}:?\d{2})?$/
      or exit 1;
    my $t = timegm($6, $5, $4, $3, $2 - 1, $1);
    if (defined $7 && $7 ne "Z") {
      my ($sign, $hh, $mm) = $7 =~ /^([+-])(\d{2}):?(\d{2})$/;
      $t -= ($hh * 3600 + $mm * 60) * ($sign eq "-" ? -1 : 1);
    }
    print $t;
  ' -- "$1"
}

capacity_stamp() {  # $1 = epoch, $2 = strftime format; prints local wall clock
  perl -e 'use POSIX qw(strftime); print strftime($ARGV[1], localtime($ARGV[0]))' \
    -- "$1" "$2"
}

# Output-token headroom left in the station's current five-hour block — the
# proxy both callers use for "capacity". The ceiling is CAPACITY_TOKEN_LIMIT
# when pinned, otherwise the busiest *completed* block ccusage can still see,
# which is the same "most you have ever managed" heuristic ccusage's own
# --token-limit max uses. No completed block means no ceiling, and no ceiling
# means we refuse to guess: the caller falls back to its own conservative
# default and says so.
#
# Sets CAP_USED / CAP_LIMIT / CAP_REMAINING / CAP_PCT, plus CAP_RESET — the
# epoch at which the active block rolls over, i.e. when spending becomes
# possible again. CAP_RESET is best-effort and independent of the return code:
# a station with no completed block has no usable ceiling but may still have a
# perfectly good reset time, which is exactly what a deferral needs.
# Non-zero when the headroom is unknown.
capacity_for() {  # $1 = the station's claude config dir
  local json row used seen reset_iso
  CAP_USED=0; CAP_LIMIT=0; CAP_REMAINING=0; CAP_PCT=0; CAP_RESET=""
  json=$(capacity_blocks "$1") || return 1
  row=$(printf '%s' "$json" | jq -r '
    [.blocks[]? | select((.isGap // false) | not)] as $b
    | ([$b[] | select(.isActive == true)] | first) as $active
    | ([$b[] | select(.isActive == true) | .tokenCounts.outputTokens // 0] | add // 0) as $used
    | ([$b[] | select((.isActive // false) | not) | .tokenCounts.outputTokens // 0] | max // 0) as $seen
    | [$used, $seen, ($active.usageLimitResetTime // $active.endTime // "")]
    | @tsv' 2>/dev/null) || return 1
  used=$(printf '%s' "$row" | cut -f1)
  seen=$(printf '%s' "$row" | cut -f2)
  reset_iso=$(printf '%s' "$row" | cut -f3)
  case "${used:-}" in ''|*[!0-9]*) used=0 ;; esac
  case "${seen:-}" in ''|*[!0-9]*) seen=0 ;; esac
  [ -z "$reset_iso" ] || CAP_RESET=$(capacity_epoch_of "$reset_iso") || CAP_RESET=""
  if [ -n "$CAPACITY_TOKEN_LIMIT" ] && [ -z "${CAPACITY_TOKEN_LIMIT//[0-9]/}" ] \
     && [ "$CAPACITY_TOKEN_LIMIT" -gt 0 ]; then
    CAP_LIMIT="$CAPACITY_TOKEN_LIMIT"
  elif [ "$seen" -gt 0 ]; then
    CAP_LIMIT="$seen"
  else
    return 1
  fi
  [ "$CAP_LIMIT" -ge "$used" ] || CAP_LIMIT="$used"
  CAP_USED="$used"
  CAP_REMAINING=$((CAP_LIMIT - used))
  CAP_PCT=$((CAP_REMAINING * 100 / CAP_LIMIT))
  return 0
}
