# Chalkwork shell integration for zsh: see .zshenv here. Reached only from shells that kept this
# ZDOTDIR (non-interactive login shells); interactive ones restored the user's.
if [[ -n "${CHALKWORK_ZSH_ZDOTDIR+X}" ]]; then
  [[ ! -r "$CHALKWORK_ZSH_ZDOTDIR/.zlogout" ]] || 'builtin' 'source' '--' "$CHALKWORK_ZSH_ZDOTDIR/.zlogout"
else
  [[ ! -r "$HOME/.zlogout" ]] || 'builtin' 'source' '--' "$HOME/.zlogout"
fi
