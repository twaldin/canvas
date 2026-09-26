#!/bin/sh
# A development instance of Canvas for this checkout, isolated from the installed app and from
# other agents' instances (own CANVAS_HOME: socket, boards, log). See docs/testing.md.
#
#   scripts/dev.sh start [root]     build + bundle, launch without activating on the testing Space
#   scripts/dev.sh restart [root]   rebuild and relaunch, keeping terminal sessions (zmx) alive
#   scripts/dev.sh stop             quit and kill this instance's zmx sessions
#   scripts/dev.sh cli <args…>      run the canvas CLI against this instance
#   scripts/dev.sh snapshot [file]  write view.snapshot to a PNG (default .canvas-home/snapshot.png)
#   scripts/dev.sh input <args…>    replay input (scripts/dev-input.swift) into this instance
#   scripts/dev.sh sessions         list this instance's zmx sessions
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
home="$repo/.canvas-home"
app="$repo/.build/Canvas.app"
space="${CANVAS_DEV_SPACE:-8}"
yabai="${YABAI:-$HOME/Applications/Yabai.app/Contents/MacOS/yabai}"
export CANVAS_SOCKET="$home/canvas.sock"
# zmx keys its socket directory off TMPDIR; match the GUI app's.
zmx_env() { TMPDIR="$(getconf DARWIN_USER_TEMP_DIR)" "$@"; }

running_pid() {
  [ -f "$home/pid" ] || return 1
  pid="$(cat "$home/pid")"
  kill -0 "$pid" 2>/dev/null && echo "$pid"
}

quit() {
  pid="$(running_pid)" || return 0
  kill "$pid"
  i=0
  while kill -0 "$pid" 2>/dev/null && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  rm -f "$home/pid"
}

board_ids() {
  for file in "$home"/boards/*.json; do [ -e "$file" ] && basename "$file" .json; done
}

sessions() {
  ids="$(board_ids)"
  [ -n "$ids" ] || return 0
  zmx_env zmx list 2>/dev/null | while IFS= read -r line; do
    for id in $ids; do
      case "$line" in *"canvas.board=$id"*) echo "$line" | sed -E 's/.*name=([^[:space:]]+).*/\1/' ;; esac
    done
  done
}

launch() {
  root="${1:-$repo}"
  "$repo/scripts/bundle.sh" >/dev/null
  mkdir -p "$home"
  rm -f "$CANVAS_SOCKET"
  if [ -x "$yabai" ] && ! "$yabai" -m rule --list 2>/dev/null | grep -q '"label":"canvas-dev"'; then
    "$yabai" -m rule --add label=canvas-dev app="^Canvas$" space="$space" manage=off grid=1:1:0:0:1:1 >/dev/null
  fi
  open -g -n --stdout "$home/app.log" --stderr "$home/app.log" \
    --env CANVAS_HOME="$home" --env CANVAS_NO_ACTIVATE=1 --env CANVAS_DEV_INPUT=1 --env CANVAS_ROOT="$root" "$app"
  i=0
  while [ ! -S "$CANVAS_SOCKET" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  [ -S "$CANVAS_SOCKET" ] || { echo "Canvas did not open its socket; see $home/app.log" >&2; exit 1; }
  pgrep -n -f "$app/Contents/MacOS/Canvas" > "$home/pid"
  echo "Canvas pid $(cat "$home/pid"), CANVAS_SOCKET=$CANVAS_SOCKET"
}

case "${1:-}" in
  start) quit; launch "${2:-}" ;;
  restart) quit; launch "${2:-}" ;;
  stop)
    quit
    for name in $(sessions); do zmx_env zmx kill "$name" --force >/dev/null 2>&1 || true; done
    ;;
  cli) shift; exec bun "$repo/cli/canvas.ts" "$@" ;;
  snapshot)
    out="${2:-$home/snapshot.png}"
    bun "$repo/cli/canvas.ts" view.snapshot --out "$out" >/dev/null && echo "$out"
    ;;
  input)
    shift
    pid="$(running_pid)" || { echo "no running dev instance" >&2; exit 1; }
    exec "$repo/.build/dev-input" "$pid" "$@"
    ;;
  sessions) sessions ;;
  *) sed -n '2,12p' "$0" >&2; exit 2 ;;
esac
