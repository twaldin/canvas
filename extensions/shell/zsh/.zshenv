# Canvas shell integration for zsh (docs/contracts.md "Terminal tile environment").
#
# Terminal tiles start zsh with ZDOTDIR pointing here (the user's own ZDOTDIR, if any, in
# CANVAS_ZSH_ZDOTDIR). Each of these startup files sources the user's file of the same name with
# the user's ZDOTDIR in place, and the last one zsh reads puts Canvas's bin back at the front of
# PATH: the user's files may prepend directories (e.g. ~/.local/bin, where Claude Code installs
# itself) that would shadow Canvas's claude and codex wrappers.
#
# Interactive shells then get the user's ZDOTDIR back, as if Canvas were not there. A tile that
# runs a command first (`zsh -l -c '<command>; exec zsh -l'`, e.g. resuming an agent) keeps this
# integration for the command and the shell that follows it.
#
# Quoted builtins: these files can run with the user's aliases defined.

'builtin' 'typeset' -g _canvas_zdotdir="${${(%):-%x}:A:h}"

# Runs the user's startup file <name> with their ZDOTDIR, then points ZDOTDIR back here.
_canvas_source() {
  if [[ -n "${CANVAS_ZSH_ZDOTDIR+X}" ]]; then
    'builtin' 'export' ZDOTDIR="$CANVAS_ZSH_ZDOTDIR"
  else
    'builtin' 'unset' 'ZDOTDIR'
  fi
  # Zsh reads rc files only when readable, and treats an unset ZDOTDIR as HOME.
  'builtin' 'typeset' _canvas_file="${ZDOTDIR-$HOME}/$1"
  [[ ! -r "$_canvas_file" ]] || 'builtin' 'source' '--' "$_canvas_file"
  # The user's file may have set its own ZDOTDIR (e.g. ~/.config/zsh); zsh reads the rest there.
  if [[ -n "${ZDOTDIR+X}" ]]; then
    'builtin' 'export' CANVAS_ZSH_ZDOTDIR="$ZDOTDIR"
  fi
  'builtin' 'export' ZDOTDIR="$_canvas_zdotdir"
}

# Before each prompt: the shell's directory (OSC 7, unencoded like Ghostty's own integration), so
# `path:line` references in the tile resolve against where the user cd'ed.
_canvas_report_cwd() {
  'builtin' 'printf' '\e]7;kitty-shell-cwd://%s%s\a' "$HOST" "$PWD"
}

# After the last startup file: Canvas's bin first on PATH; interactive shells restore ZDOTDIR and
# report their directory before each prompt.
_canvas_finish() {
  'builtin' 'typeset' _canvas_bin="${_canvas_zdotdir:h:h:h}/bin"
  path=("$_canvas_bin" ${path:#$_canvas_bin})
  if [[ -o 'interactive' ]]; then
    precmd_functions=(${precmd_functions:#_canvas_report_cwd} _canvas_report_cwd)
    if [[ -n "${CANVAS_ZSH_ZDOTDIR+X}" ]]; then
      'builtin' 'export' ZDOTDIR="$CANVAS_ZSH_ZDOTDIR"
    else
      'builtin' 'unset' 'ZDOTDIR'
    fi
    'builtin' 'unset' 'CANVAS_ZSH_ZDOTDIR'
  fi
  'builtin' 'unfunction' '_canvas_source' '_canvas_finish'
  'builtin' 'unset' '_canvas_zdotdir'
}

_canvas_source .zshenv
# Non-interactive, non-login shells (`zsh -c`) read no other startup file.
[[ -o 'interactive' || -o 'login' ]] || _canvas_finish
