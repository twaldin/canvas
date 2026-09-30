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
# Places the replica's window with yabai, like scripts/dev.sh (docs/testing.md).
yabai="${YABAI:-$HOME/Applications/Yabai.app/Contents/MacOS/yabai}"
[ -x "$yabai" ] || yabai="$(command -v yabai || echo "$yabai")"
need_yabai() {
  [ -x "$yabai" ] || { echo "scripts/perf-replica.sh $1 needs yabai (https://github.com/koekeishiya/yabai): install it, or set YABAI to its path" >&2; exit 1; }
}
park="${CANVAS_DEV_PARK_SPACE:-7}"

# The pid file counts only while that process owns this home's socket (see scripts/dev.sh).
pid() { [ -f "$home/pid" ] && kill -0 "$(cat "$home/pid")" 2>/dev/null && lsof -t "$home/canvas.sock" 2>/dev/null | grep -qx "$(cat "$home/pid")" && cat "$home/pid"; }
window() { "$yabai" -m query --windows | python3 -c "import json,sys; print(next((w['id'] for w in json.load(sys.stdin) if w['pid']==$(pid)), ''))"; }

case "${1:-}" in
  start)
    need_yabai start
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
    # The testing Space lives on the virtual screen; park the first window on an unviewed Space
    # with a one-shot rule, removed once placed (see scripts/dev.sh launch).
    rule="canvas-dev-$(printf %s "$home" | cksum | cut -d' ' -f1)"
    "$yabai" -m rule --remove "$rule" >/dev/null 2>&1 || true
    "$yabai" -m rule --add --one-shot label="$rule" app="^Canvas$" space="$park" manage=off grid=1:1:0:0:1:1 >/dev/null
    # PERF_MALLOC_STACKS=1 records allocation stacks for `malloc_history <pid> <address>`. The
    # replica runs from a copy that carries this environment (scripts/dev-bundle.sh).
    set -- CANVAS_NO_ACTIVATE=1 CANVAS_DEV_INPUT=1 CANVAS_DEV_PERF=1 CANVAS_ROOT="$root"
    [ -z "${PERF_MALLOC_STACKS:-}" ] || set -- "$@" MallocStackLogging=1
    bundle="$("$repo/scripts/dev-bundle.sh" "$app" "$home" "$@")"
    n=$#
    while [ "$n" -gt 0 ]; do set -- "$@" --env "$1"; shift; n=$((n - 1)); done
    open -g -n --stdout "$home/app.log" --stderr "$home/app.log" --env CANVAS_HOME="$home" "$@" "$bundle"
    i=0; while [ ! -S "$home/canvas.sock" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
    lsof -t "$home/canvas.sock" | head -n 1 > "$home/pid"
    i=0; while [ -z "$(window)" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
    space="$(CANVAS_DEV_SPACE= sh -c ". /dev/null; $(sed -n '/^test_space()/,/^}/p' "$repo/scripts/dev.sh"); yabai=$yabai; test_space")"
    "$yabai" -m window "$(window)" --space "$space"
    "$yabai" -m window "$(window)" --grid 1:1:0:0:1:1
    "$yabai" -m rule --remove "$rule" >/dev/null 2>&1 || true
    echo "replica pid $(pid) window $(window) on Space $space, CANVAS_SOCKET=$home/canvas.sock"
    ;;
  stop)
    p="$(pid || true)"; [ -n "$p" ] && kill "$p" && while kill -0 "$p" 2>/dev/null; do sleep 0.1; done
    rm -rf "$home"
    ;;
  pid) pid ;;
  window) need_yabai window; window ;;
  *) sed -n '2,10p' "$0" >&2; exit 2 ;;
esac
