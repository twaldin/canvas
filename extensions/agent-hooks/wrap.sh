# Shared by Canvas's agent wrappers bin/claude, bin/codex, bin/gemini and bin/opencode
# (docs/contracts.md "Agent integrations"): find the real agent binary and decide whether to
# integrate.

# The next <name> on PATH that isn't a Canvas wrapper (this instance's or another's bin, which
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

# Plain: outside Canvas, opted out (CANVAS_AGENT_HOOKS=0), or inside an agent this wrapper already
# integrated (CANVAS_AGENT is set: a nested agent must not report as the tile's agent).
canvas_integrate() {
  [ "${CANVAS_ENV-}" = 1 ] && [ -n "${CANVAS_TILE_ID-}" ] && [ -n "${CANVAS_SOCKET-}" ] &&
    [ "${CANVAS_AGENT_HOOKS-}" != 0 ] && [ -z "${CANVAS_AGENT-}" ]
}

canvas_agent_real() {
  canvas_real "$1" && return 0
  printf 'canvas: %s is not installed (no %s on PATH besides Canvas'"'"'s wrapper %s)\n' "$1" "$1" "$0" >&2
  exit 127
}

# Gemini CLI and opencode take their integration from environment variables, which everything the
# agent starts inherits. `canvas_env_set VAR value` exports VAR and keeps the user's own value in
# CANVAS_USER_<VAR>; `canvas_env_restore VAR` puts it back (unset when it was unset or empty), so
# the same agent started inside the integrated one runs with the user's settings, plain.
canvas_env_set() {
  eval "export CANVAS_USER_$1=\"\${$1-}\"; export $1=\"\$2\""
}

canvas_env_restore() {
  eval "[ -n \"\${CANVAS_USER_$1+x}\" ] || return 0
    if [ -n \"\$CANVAS_USER_$1\" ]; then export $1=\"\$CANVAS_USER_$1\"; else unset $1; fi
    unset CANVAS_USER_$1"
}
