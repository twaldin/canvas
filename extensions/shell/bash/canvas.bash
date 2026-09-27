# Canvas shell integration for bash (docs/contracts.md "Terminal tile environment").
#
# Terminal tiles export PROMPT_COMMAND='. <this file>', so bash runs it before each prompt, after
# the user's startup files (which keep an inherited PROMPT_COMMAND when they add their own). The
# first run puts Canvas's bin back at the front of PATH, where those files may have put other
# directories (e.g. ~/.local/bin, where Claude Code installs itself) that would shadow Canvas's
# claude and codex wrappers. Every run reports the directory as a percent-encoded file URL (OSC 7,
# as macOS Terminal's own bashrc does), so `path:line` references in the tile resolve against
# where the user cd'ed.
__canvas_url=''
__canvas_i=0
while [ "$__canvas_i" -lt "${#PWD}" ]; do
  __canvas_ch="${PWD:__canvas_i:1}"
  case "$__canvas_ch" in
    [/._~A-Za-z0-9-]) __canvas_url+="$__canvas_ch" ;;
    *) __canvas_url+="$(LC_ALL=C printf '%%%02X' "'$__canvas_ch")" ;;
  esac
  __canvas_i=$((__canvas_i + 1))
done
printf '\e]7;file://%s%s\a' "$HOSTNAME" "$__canvas_url"
unset __canvas_url __canvas_i __canvas_ch
[ -n "${__canvas_path_done-}" ] && return
__canvas_path_done=1
__canvas_bin="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../bin" && pwd)"
__canvas_path=":$PATH:"
__canvas_path="${__canvas_path//:$__canvas_bin:/:}"
__canvas_path="${__canvas_path#:}"
PATH="$__canvas_bin:${__canvas_path%:}"
unset __canvas_bin __canvas_path
