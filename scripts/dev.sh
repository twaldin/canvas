#!/bin/sh
# A development instance of Canvas for this checkout, isolated from the installed app and from
# other agents' instances (own CANVAS_HOME: socket, boards, log). See docs/testing.md.
#
#   scripts/dev.sh start [root]     build + bundle, launch without activating on the testing Space
#   scripts/dev.sh restart [root]   rebuild and relaunch, keeping terminal sessions (zmx) alive
#   scripts/dev.sh stop             quit and kill this instance's zmx sessions
#   scripts/dev.sh cli <args…>      run the canvas CLI against this instance
#   scripts/dev.sh shot [file]      real pixels: WindowServer capture of the window (default .canvas-home/shot.png)
#   scripts/dev.sh snapshot [file]  view.snapshot (in-process render, the agent-facing view) to a PNG
#   scripts/dev.sh move [space]     move the window to a Space (default: the testing Space) and maximize it
#   scripts/dev.sh input <args…>    replay input (scripts/dev-input.swift) into this instance
#   scripts/dev.sh sessions         list this instance's zmx sessions
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
home="$repo/.canvas-home"
app="$repo/.build/Canvas.app"
yabai="${YABAI:-$HOME/Applications/Yabai.app/Contents/MacOS/yabai}"
# The testing Space: CANVAS_DEV_SPACE, else the first Space of the BetterDisplay virtual screen
# named CANVAS_DEV_DISPLAY (default "CanvasTest"; a headless monitor, so the window renders while
# nobody looks at it), else Space 8. Parallel agents each get their own screen (CanvasTest2, …).
# CANVAS_DEV_SPACE=8 puts the window where Tim watches.
test_space() {
  if [ -n "${CANVAS_DEV_SPACE:-}" ]; then echo "$CANVAS_DEV_SPACE"; return; fi
  id="$(betterdisplaycli get --name="${CANVAS_DEV_DISPLAY:-CanvasTest}" --identifiers 2>/dev/null | sed -n 's/.*"displayID" : "\([0-9]*\)".*/\1/p' | head -n 1)"
  space="$([ -n "$id" ] && "$yabai" -m query --displays 2>/dev/null | python3 -c "import json,sys; print(next((d['spaces'][0] for d in json.load(sys.stdin) if d['id']==$id), ''))" 2>/dev/null)"
  echo "${space:-8}"
}

window_id() {
  pid="$(running_pid)" || { echo "no running dev instance" >&2; exit 1; }
  "$yabai" -m query --windows | python3 -c "import json,sys; print(next((w['id'] for w in json.load(sys.stdin) if w['pid']==$pid), ''))"
}
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
  # A wedged instance must not outlive its pid file: restart would start a second one on the
  # same sockets and boards.
  if kill -0 "$pid" 2>/dev/null; then
    echo "Canvas $pid did not quit; killing it" >&2
    kill -9 "$pid"
    while kill -0 "$pid" 2>/dev/null; do sleep 0.1; done
  fi
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
  # yabai can't place a new window on another display's Space (it lands on the Space being
  # viewed), so a one-shot rule parks this launch's first window on Space 7, an unviewed Space on
  # the built-in display (8 is where Tim watches), and it moves to the testing Space once it
  # exists. One-shot and removed afterwards: a standing rule on app=Canvas also grabbed every later
  # window (tabs, other instances, Tim's own boards) and hid them on Space 7.
  rule="canvas-dev-$(printf %s "$home" | cksum | cut -d' ' -f1)"
  if [ -x "$yabai" ]; then
    "$yabai" -m rule --remove "$rule" >/dev/null 2>&1 || true
    "$yabai" -m rule --add --one-shot label="$rule" app="^Canvas$" space=7 manage=off grid=1:1:0:0:1:1 >/dev/null
  fi
  open -g -n --stdout "$home/app.log" --stderr "$home/app.log" \
    --env CANVAS_HOME="$home" --env CANVAS_NO_ACTIVATE=1 --env CANVAS_DEV_INPUT=1 --env CANVAS_ROOT="$root" "$app"
  i=0
  while [ ! -S "$CANVAS_SOCKET" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  [ -S "$CANVAS_SOCKET" ] || { echo "Canvas did not open its socket; see $home/app.log" >&2; exit 1; }
  pgrep -n -f "$app/Contents/MacOS/Canvas" > "$home/pid"
  target="$(test_space)"
  if [ -x "$yabai" ] && [ "$target" != 7 ]; then
    i=0
    while [ -z "$(window_id)" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
    wid="$(window_id)"
    [ -n "$wid" ] && "$yabai" -m window "$wid" --space "$target" && "$yabai" -m window "$wid" --grid 1:1:0:0:1:1
  fi
  [ -x "$yabai" ] && { "$yabai" -m rule --remove "$rule" >/dev/null 2>&1 || true; }
  echo "Canvas pid $(cat "$home/pid") on Space $target, CANVAS_SOCKET=$CANVAS_SOCKET"
}

case "${1:-}" in
  start) quit; launch "${2:-}" ;;
  restart) quit; launch "${2:-}" ;;
  stop)
    quit
    for name in $(sessions); do zmx_env zmx kill "$name" --force >/dev/null 2>&1 || true; done
    ;;
  cli) shift; exec bun "$repo/cli/canvas.ts" "$@" ;;
  shot)
    out="${2:-$home/shot.png}"
    wid="$(window_id)"
    [ -n "$wid" ] || { echo "no Canvas window" >&2; exit 1; }
    # Only a displayed Space is composited; anything else would be a stale frame.
    visible="$("$yabai" -m query --windows --window "$wid" | python3 -c "import json,sys; print(json.load(sys.stdin)['is-visible'])")"
    [ "$visible" = "True" ] || { echo "window $wid is not on a displayed Space; its pixels would be stale (scripts/dev.sh move)" >&2; exit 1; }
    screencapture -x -o -l "$wid" "$out" && echo "$out"
    ;;
  move)
    wid="$(window_id)"
    [ -n "$wid" ] || { echo "no Canvas window" >&2; exit 1; }
    "$yabai" -m window "$wid" --space "${2:-$(test_space)}"
    "$yabai" -m window "$wid" --grid 1:1:0:0:1:1
    ;;
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
  *) sed -n '2,13p' "$0" >&2; exit 2 ;;
esac
