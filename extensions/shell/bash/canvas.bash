# Canvas shell integration for bash (docs/contracts.md "Terminal tile environment").
#
# Terminal tiles export PROMPT_COMMAND='. <this file>', so bash runs it before each prompt, after
# the user's startup files (which keep an inherited PROMPT_COMMAND when they add their own). The
# first run puts Canvas's bin back at the front of PATH, where those files may have put other
# directories (e.g. ~/.local/bin, where Claude Code installs itself) that would shadow Canvas's
# claude and codex wrappers; later runs only report the directory (OSC 7, unencoded like Ghostty's
# own integration), so `path:line` references in the tile resolve against where the user cd'ed.
printf '\e]7;kitty-shell-cwd://%s%s\a' "$HOSTNAME" "$PWD"
[ -n "${__canvas_path_done-}" ] && return
__canvas_path_done=1
__canvas_bin="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../bin" && pwd)"
__canvas_path=":$PATH:"
__canvas_path="${__canvas_path//:$__canvas_bin:/:}"
__canvas_path="${__canvas_path#:}"
PATH="$__canvas_bin:${__canvas_path%:}"
unset __canvas_bin __canvas_path
