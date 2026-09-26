#!/bin/sh
# A second Canvas instance showing a copy of a dev board, for performance work on the testing
# Space while the original stays in use. Terminal tiles are dropped so the copy never attaches to
# the original's zmx sessions.
#
#   scripts/perf-replica.sh start <board-id|file> [app]   copy .canvas-home/boards/<id>.json (or a board file) and launch
#   PERF_HOME (default /tmp/canvas-perf-home) and CANVAS_DEV_DISPLAY keep parallel replicas apart.
#   scripts/perf-replica.sh stop
#   scripts/perf-replica.sh pid | window
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
home="${PERF_HOME:-/tmp/canvas-perf-home}"
yabai="${YABAI:-$HOME/Applications/Yabai.app/Contents/MacOS/yabai}"

pid() { [ -f "$home/pid" ] && kill -0 "$(cat "$home/pid")" 2>/dev/null && cat "$home/pid"; }
window() { "$yabai" -m query --windows | python3 -c "import json,sys; print(next((w['id'] for w in json.load(sys.stdin) if w['pid']==$(pid)), ''))"; }

case "${1:-}" in
  start)
    source="$2"; app="${3:-$repo/.build/Canvas.app}"
    [ -f "$source" ] || source="$repo/.canvas-home/boards/$source.json"
    board="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['id'])" "$source")"
    [ -z "$(pid || true)" ] || { echo "replica already running" >&2; exit 1; }
    rm -rf "$home"; mkdir -p "$home/boards"
    python3 - "$source" "$home/boards/$board.json" <<'EOF'
import json, sys
board = json.load(open(sys.argv[1]))
objects = board["objects"] if isinstance(board["objects"], list) else list(board["objects"].values())
drop = {o["id"] for o in objects if o["type"] == "terminal"}
kept = [o for o in objects if o["id"] not in drop]
board["objects"] = kept if isinstance(board["objects"], list) else {o["id"]: o for o in kept}
json.dump(board, open(sys.argv[2], "w"))
print(f"{len(kept)} objects ({len(drop)} terminals dropped)")
EOF
    root="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['root'])" "$home/boards/$board.json")"
    # The testing Space lives on the virtual screen; park on Space 7 first (see docs/testing.md).
    "$yabai" -m rule --remove canvas-dev >/dev/null 2>&1 || true
    "$yabai" -m rule --add label=canvas-dev app="^Canvas$" space=7 manage=off grid=1:1:0:0:1:1 >/dev/null
    # PERF_MALLOC_STACKS=1 records allocation stacks for `malloc_history <pid> <address>`.
    open -g -n --stdout "$home/app.log" --stderr "$home/app.log" \
      ${PERF_MALLOC_STACKS:+--env MallocStackLogging=1} --env CANVAS_HOME="$home" --env CANVAS_NO_ACTIVATE=1 --env CANVAS_DEV_INPUT=1 --env CANVAS_ROOT="$root" "$app"
    i=0; while [ ! -S "$home/canvas.sock" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
    pgrep -n -f "$app/Contents/MacOS/Canvas" > "$home/pid"
    i=0; while [ -z "$(window)" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
    space="$(CANVAS_DEV_SPACE= sh -c ". /dev/null; $(sed -n '/^test_space()/,/^}/p' "$repo/scripts/dev.sh"); yabai=$yabai; test_space")"
    "$yabai" -m window "$(window)" --space "$space"
    "$yabai" -m window "$(window)" --grid 1:1:0:0:1:1
    echo "replica pid $(pid) window $(window) on Space $space, CANVAS_SOCKET=$home/canvas.sock"
    ;;
  stop)
    p="$(pid || true)"; [ -n "$p" ] && kill "$p" && while kill -0 "$p" 2>/dev/null; do sleep 0.1; done
    rm -rf "$home"
    ;;
  pid) pid ;;
  window) window ;;
  *) sed -n '2,10p' "$0" >&2; exit 2 ;;
esac
