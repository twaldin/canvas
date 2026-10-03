# Shared by easl's agent wrappers bin/claude, bin/codex, bin/gemini, bin/opencode and bin/aider
# (docs/contracts.md "Agent integrations"): find the real agent binary and decide whether to
# integrate.

# The next <name> on PATH that isn't an easl wrapper (this instance's or another's bin, which
# sits beside extensions/agent-hooks). Never recurses into a wrapper.
canvas_real() {
  saved_ifs=$IFS
  IFS=:
  set -f
  for dir in $PATH; do
    [ -n "$dir" ] || dir=.
    [ -f "$dir/../extensions/agent-hooks/wrap.sh" ] && continue
    if [ -f "$dir/$1" ] && [ -x "$dir/$1" ]; then
      IFS=$saved_ifs
      set +f
      printf '%s\n' "$dir/$1"
      return 0
    fi
  done
  IFS=$saved_ifs
  set +f
  return 1
}

# Plain: outside easl, opted out (EASL_AGENT_HOOKS=0), or inside an agent this wrapper already
# integrated (EASL_AGENT is set: a nested agent must not report as the tile's agent).
canvas_integrate() {
  [ "${EASL_ENV-}" = 1 ] && [ -n "${EASL_TILE_ID-}" ] && [ -n "${EASL_SOCKET-}" ] &&
    [ "${EASL_AGENT_HOOKS-}" != 0 ] && [ -z "${EASL_AGENT-}" ]
}

canvas_agent_real() {
  canvas_real "$1" && return 0
  printf 'easl: %s is not installed (no %s on PATH besides easl'"'"'s wrapper %s)\n' "$1" "$1" "$0" >&2
  exit 127
}

# Gemini CLI and opencode take their integration from environment variables, which everything the
# agent starts inherits. `canvas_env_set VAR value` exports VAR and keeps the user's own value in
# EASL_USER_<VAR>; `canvas_env_restore VAR` puts it back (unset when it was unset or empty), so
# the same agent started inside the integrated one runs with the user's settings, plain.
canvas_env_set() {
  eval "export EASL_USER_$1=\"\${$1-}\"; export $1=\"\$2\""
}

canvas_env_restore() {
  eval "[ -n \"\${EASL_USER_$1+x}\" ] || return 0
    if [ -n \"\$EASL_USER_$1\" ]; then export $1=\"\$EASL_USER_$1\"; else unset $1; fi
    unset EASL_USER_$1"
}
