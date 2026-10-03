# easl shell integration for zsh (docs/contracts.md "Terminal tile environment").
#
# Terminal tiles start zsh with ZDOTDIR pointing here (the user's own ZDOTDIR, if any, in
# EASL_ZSH_ZDOTDIR). Each of these startup files sources the user's file of the same name with
# the user's ZDOTDIR in place, and the last one zsh reads puts easl's bin back at the front of
# PATH: the user's files may prepend directories (e.g. ~/.local/bin, where Claude Code installs
# itself) that would shadow easl's claude and codex wrappers.
#
# Interactive shells then get the user's ZDOTDIR back, as if easl were not there. A tile that
# runs a command first (`zsh -l -c '<command>; exec zsh -l'`, e.g. resuming an agent) keeps this
# integration for the command and the shell that follows it.
#
# Interactive shells also get Ghostty's shell integration (OSC 133 prompt marks: jump to prompt,
# click to move the cursor, command exit status), which Ghostty injects only into shells it starts
# itself: the app passes its directory in EASL_GHOSTTY_INTEGRATION unless the user's Ghostty
# config says `shell-integration = none`. It loads after the user's files, so their prompt
# framework's hooks run first, and not when they loaded one themselves.
#
# Quoted builtins: these files can run with the user's aliases defined.

'builtin' 'typeset' -g _canvas_zdotdir="${${(%):-%x}:A:h}"

# Runs the user's startup file <name> with their ZDOTDIR, then points ZDOTDIR back here.
_canvas_source() {
  if [[ -n "${EASL_ZSH_ZDOTDIR+X}" ]]; then
    'builtin' 'export' ZDOTDIR="$EASL_ZSH_ZDOTDIR"
  else
    'builtin' 'unset' 'ZDOTDIR'
  fi
  # Zsh reads rc files only when readable, and treats an unset ZDOTDIR as HOME.
  'builtin' 'typeset' _canvas_file="${ZDOTDIR-$HOME}/$1"
  # macOS's /etc/zshrc, run while ZDOTDIR is here, puts history in this directory (inside the
  # app): the user's ZDOTDIR or HOME instead, before their file, which may choose its own.
  [[ "${HISTFILE-}" != "$_canvas_zdotdir"/* ]] || HISTFILE="${ZDOTDIR-$HOME}/${HISTFILE:t}"
  [[ ! -r "$_canvas_file" ]] || 'builtin' 'source' '--' "$_canvas_file"
  # The user's file may have set its own ZDOTDIR (e.g. ~/.config/zsh); zsh reads the rest there.
  if [[ -n "${ZDOTDIR+X}" ]]; then
    'builtin' 'export' EASL_ZSH_ZDOTDIR="$ZDOTDIR"
  fi
  'builtin' 'export' ZDOTDIR="$_canvas_zdotdir"
}

# Before each prompt: the shell's directory as a percent-encoded file URL (OSC 7, as macOS
# Terminal's own zshrc does), so `path:line` references in the tile resolve against where the
# user cd'ed.
_canvas_report_cwd() {
  'builtin' 'local' _canvas_url='' _canvas_ch _canvas_hex _canvas_i LC_CTYPE=C LC_COLLATE=C LC_ALL= LANG=
  for ((_canvas_i = 1; _canvas_i <= ${#PWD}; ++_canvas_i)); do
    _canvas_ch="$PWD[_canvas_i]"
    if [[ "$_canvas_ch" == [/._~A-Za-z0-9-] ]]; then
      _canvas_url+="$_canvas_ch"
    else
      'builtin' 'printf' -v _canvas_hex '%02X' "'$_canvas_ch"
      _canvas_url+="%${_canvas_hex:(-2)}"
    fi
  done
  'builtin' 'printf' '\e]7;file://%s%s\a' "$HOST" "$_canvas_url"
}

# After the last startup file: easl's bin first on PATH; interactive shells restore ZDOTDIR,
# report their directory before each prompt, and load Ghostty's shell integration.
_canvas_finish() {
  'builtin' 'typeset' _canvas_bin="${_canvas_zdotdir:h:h:h}/bin"
  path=("$_canvas_bin" ${path:#$_canvas_bin})
  if [[ -o 'interactive' ]]; then
    precmd_functions=(${precmd_functions:#_canvas_report_cwd} _canvas_report_cwd)
    if [[ -n "${EASL_GHOSTTY_INTEGRATION-}" ]] && (( ! ${+_ghostty_integration_loaded} && ! ${+_ghostty_state} )) \
        && [[ -r "$EASL_GHOSTTY_INTEGRATION/zsh/ghostty-integration" ]]; then
      'builtin' 'source' '--' "$EASL_GHOSTTY_INTEGRATION/zsh/ghostty-integration"
    fi
    if [[ -n "${EASL_ZSH_ZDOTDIR+X}" ]]; then
      'builtin' 'export' ZDOTDIR="$EASL_ZSH_ZDOTDIR"
    else
      'builtin' 'unset' 'ZDOTDIR'
    fi
    'builtin' 'unset' 'EASL_ZSH_ZDOTDIR'
  fi
  'builtin' 'unfunction' '_canvas_source' '_canvas_finish'
  'builtin' 'unset' '_canvas_zdotdir'
}

_canvas_source .zshenv
# Non-interactive, non-login shells (`zsh -c`) read no other startup file.
[[ -o 'interactive' || -o 'login' ]] || _canvas_finish
