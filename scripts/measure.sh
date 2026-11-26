#!/bin/bash
# Measures Telltale's memory (phys_footprint) and CPU in standard configurations and prints a Markdown table.
#
#   ./scripts/measure.sh                  # uses build/Telltale.app (run ./build.sh first)
#   ./scripts/measure.sh --compare Stats  # also measures another running app over the same windows
#   SECONDS_PER_RUN=60 ./scripts/measure.sh
#
# CPU is reported as % of one core: CPU time used ÷ wall time. Your Telltale settings are restored afterwards.
set -euo pipefail
cd "$(dirname "$0")/.."

BIN="build/Telltale.app/Contents/MacOS/Telltale"
DOMAIN="io.github.pri-te-sh.telltale"
RUN=${SECONDS_PER_RUN:-60}
WARMUP=20
COMPARE=""
[ "${1:-}" = "--compare" ] && COMPARE="${2:-}"
[ -x "$BIN" ] || { echo "Build first: ./build.sh" >&2; exit 1; }

# Save settings
saved_items=$(defaults read $DOMAIN menuBarItems 2>/dev/null || echo "__unset__")
saved_interval=$(defaults read $DOMAIN updateInterval 2>/dev/null || echo "__unset__")
restore() {
  pkill -x Telltale 2>/dev/null || true
  if [ "$saved_items" = "__unset__" ]; then defaults delete $DOMAIN menuBarItems 2>/dev/null || true; else defaults write $DOMAIN menuBarItems "$saved_items"; fi
  if [ "$saved_interval" = "__unset__" ]; then defaults delete $DOMAIN updateInterval 2>/dev/null || true; else defaults write $DOMAIN updateInterval -float "$saved_interval"; fi
  [ -d "$HOME/Applications/Telltale.app" ] && open "$HOME/Applications/Telltale.app" || true
}
trap restore EXIT

secs() { # [[dd-]hh:]mm:ss.xx -> seconds
  echo "$1" | awk -F'[-:]' '{ s=0; for (i=1;i<=NF;i++) s=s*60+$i; print s }'
}
cpu_of() { secs "$(ps -o time= -p "$1" | tr -d ' ')"; }
mem_of() { footprint -p "$1" 2>/dev/null | awk '/phys_footprint:/{print $2" "$3; exit}'; }

measure() { # label items interval extra-args
  local label=$1 items=$2 interval=$3 args=${4:-}
  pkill -x Telltale 2>/dev/null || true; sleep 0.5
  defaults write $DOMAIN menuBarItems "$items"
  defaults write $DOMAIN updateInterval -float "$interval"
  (caffeinate -dimsu -t $((WARMUP + RUN + 5)) >/dev/null 2>&1 &)
  ( "$BIN" $args >/dev/null 2>&1 & )
  sleep "$WARMUP"
  local p; p=$(pgrep -x Telltale)
  local c0 o0="" op=""; c0=$(cpu_of "$p")
  if [ -n "$COMPARE" ] && op=$(pgrep -x "$COMPARE" | head -1); then o0=$(cpu_of "$op"); fi
  sleep "$RUN"
  local c1; c1=$(cpu_of "$p")
  local cpu; cpu=$(awk -v a="$c0" -v b="$c1" -v t="$RUN" 'BEGIN{printf "%.2f%%", (b-a)/t*100}')
  local row="| $label | $(mem_of "$p") | $cpu |"
  if [ -n "$o0" ]; then
    local o1; o1=$(cpu_of "$op")
    row="$row $(mem_of "$op") | $(awk -v a="$o0" -v b="$o1" -v t="$RUN" 'BEGIN{printf "%.2f%%", (b-a)/t*100}') |"
  fi
  echo "$row"
}

header="| Configuration | Telltale memory | Telltale CPU |"
sep="|---|---|---|"
if [ -n "$COMPARE" ]; then header="$header $COMPARE memory | $COMPARE CPU |"; sep="$sep---|---|"; fi
echo "$header"; echo "$sep"
measure "Closed · icon only"                     ""                                          3
measure "Closed · 6 readouts + charts · 3 s"     "cpu,gpu,memory,network,temperature,power"  3
measure "Closed · 6 readouts + charts · 1 s"     "cpu,gpu,memory,network,temperature,power"  1
measure "Open · overview"                         ""                                          3 "--open"
