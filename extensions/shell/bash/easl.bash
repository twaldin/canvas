# Easl shell integration for bash (docs/contracts.md "Terminal tile environment").
#
# Terminal tiles export PROMPT_COMMAND='. <this file>', so bash runs it before each prompt, after
# the user's startup files (which keep an inherited PROMPT_COMMAND when they add their own). The
# first run puts Easl's bin back at the front of PATH, where those files may have put other
# directories (e.g. ~/.local/bin, where Claude Code installs itself) that would shadow Easl's
# claude and codex wrappers. Every run reports the directory as a percent-encoded file URL (OSC 7,
# as macOS Terminal's own bashrc does), so `path:line` references in the tile resolve against
# where the user cd'ed.
#
# The first run in an interactive shell also loads Ghostty's shell integration (OSC 133 prompt
# marks: jump to prompt, click to move the cursor, command exit status) from
# EASL_GHOSTTY_INTEGRATION, which the app sets unless the user's Ghostty config says
# `shell-integration = none`: Ghostty injects it only into shells it starts itself. Its hooks
# (bash-preexec) install right away rather than at the next prompt, so the first command counts.
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
if [[ $- == *i* && -n "${EASL_GHOSTTY_INTEGRATION-}" && -z "${_ghostty_integration_loaded-}" && -r "$EASL_GHOSTTY_INTEGRATION/bash/ghostty.bash" ]] \
    && ! declare -F __ghostty_precmd >/dev/null; then
  builtin source "$EASL_GHOSTTY_INTEGRATION/bash/ghostty.bash"
  if declare -F __bp_install >/dev/null && [[ -n "${__bp_install_string-}" ]]; then
    eval "$__bp_install_string"
    declare -F _ghostty_precmd >/dev/null && _ghostty_precmd
    declare -F _ghostty_mark_input >/dev/null && _ghostty_mark_input
    __bp_interactive_mode
  fi
fi
