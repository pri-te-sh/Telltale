#!/bin/bash
# Regenerates docs/assets/*.png by launching Telltale on each page and capturing only its panel window.
# Usage: ./scripts/screenshots.sh   (takes ~10 minutes: graph pages wait for history to build up)
#        ONLY="cpu power menubar" ./scripts/screenshots.sh   # capture just some of them
set -euo pipefail
cd "$(dirname "$0")/.."
./build.sh >/dev/null
swiftc -O scripts/window-id.swift -o build/window-id
BIN=build/Telltale.app/Contents/MacOS/Telltale
DOMAIN=io.github.pri-te-sh.telltale
OLD_THEME=$(defaults read $DOMAIN theme 2>/dev/null || echo aurora)
OLD_ITEMS=$(defaults read $DOMAIN menuBarItems 2>/dev/null || echo "")
OLD_INTERVAL=$(defaults read $DOMAIN updateInterval 2>/dev/null || echo 3)

want() { [ -z "${ONLY:-}" ] || [[ " $ONLY " == *" $1 "* ]]; }

shot() { # name theme wait [args...]
  local name=$1 theme=$2 wait=$3; shift 3
  want "$name" || return 0
  pkill -x Telltale 2>/dev/null || true; sleep 0.5
  defaults write $DOMAIN theme "$theme"
  "$BIN" --open --open-after="$wait" "$@" >/dev/null 2>&1 &
  sleep "$wait"
  local id="" tries=0
  while [ -z "$id" ] && [ $tries -lt 20 ]; do sleep 0.5; id=$(build/window-id); tries=$((tries + 1)); done
  sleep 1.5   # let the entrance animation finish
  if [ -n "$id" ] && screencapture -x -l "$id" "docs/assets/$name.png"; then
    echo "captured $name"
  else
    echo "SKIPPED $name (panel window not found)" >&2
  fi
}

restore() {
  pkill -x Telltale 2>/dev/null || true
  defaults write $DOMAIN theme "$OLD_THEME"
  defaults write $DOMAIN menuBarItems "$OLD_ITEMS"; defaults write $DOMAIN updateInterval -float "$OLD_INTERVAL"
  open "$HOME/Applications/Telltale.app" 2>/dev/null || true
}
trap restore EXIT
caffeinate -dimsu -w $$ &   # keep the display awake (no screensaver) until this script exits
defaults write $DOMAIN menuBarItems "temperature,power,gpu,disk"   # keeps these histories filling in the background
shot overview-aurora   aurora   40
shot overview-sunset   sunset   40
shot overview-ocean    ocean    40
shot overview-graphite graphite 40
shot memory            aurora   40 --panel=memory
shot cpu               sunset   40 --panel=cpu
shot thermals          aurora   40 --panel=thermals
shot battery           ocean     4 --panel=battery
shot gpu               aurora   40 --panel=gpu
shot power             sunset   40 --panel=power
shot devices           aurora    4 --panel=devices
shot settings          aurora    4 --panel=settings
(curl -s -o /dev/null --max-time 60 https://proof.ovh.net/files/1Gb.dat || true) &
shot network           ocean    40 --panel=network
# Menu bar readouts (rendered by the app itself after ~30 s of sampling)
if want menubar; then
pkill -x Telltale 2>/dev/null || true; sleep 0.5
defaults write $DOMAIN menuBarItems "cpu,gpu,memory,network,temperature,power"
defaults write $DOMAIN updateInterval -float 3
if "$BIN" --render-menubar="docs/assets/menubar.png" >/dev/null 2>&1; then echo "captured menubar"; else echo "SKIPPED menubar" >&2; fi
fi

