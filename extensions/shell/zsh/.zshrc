# easl shell integration for zsh: see .zshenv here.
_canvas_source .zshrc
# A non-login interactive shell reads no .zlogin.
[[ -o 'login' ]] || _canvas_finish
