# Shared by Chalkwork's agent wrappers bin/claude, bin/codex, bin/gemini, bin/opencode and bin/aider
# (docs/contracts.md "Agent integrations"): find the real agent binary and decide whether to
# integrate.

# The next <name> on PATH that isn't a Chalkwork wrapper (this instance's or another's bin, which
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

# Plain: outside Chalkwork, opted out (CHALKWORK_AGENT_HOOKS=0), or inside an agent this wrapper already
# integrated (CHALKWORK_AGENT is set: a nested agent must not report as the tile's agent).
canvas_integrate() {
  [ "${CHALKWORK_ENV-}" = 1 ] && [ -n "${CHALKWORK_TILE_ID-}" ] && [ -n "${CHALKWORK_SOCKET-}" ] &&
    [ "${CHALKWORK_AGENT_HOOKS-}" != 0 ] && [ -z "${CHALKWORK_AGENT-}" ]
}

canvas_agent_real() {
  canvas_real "$1" && return 0
  printf 'chalkwork: %s is not installed (no %s on PATH besides Chalkwork'"'"'s wrapper %s)\n' "$1" "$1" "$0" >&2
  exit 127
}

# Gemini CLI and opencode take their integration from environment variables, which everything the
# agent starts inherits. `canvas_env_set VAR value` exports VAR and keeps the user's own value in
# CHALKWORK_USER_<VAR>; `canvas_env_restore VAR` puts it back (unset when it was unset or empty), so
# the same agent started inside the integrated one runs with the user's settings, plain.
canvas_env_set() {
  eval "export CHALKWORK_USER_$1=\"\${$1-}\"; export $1=\"\$2\""
}

canvas_env_restore() {
  eval "[ -n \"\${CHALKWORK_USER_$1+x}\" ] || return 0
    if [ -n \"\$CHALKWORK_USER_$1\" ]; then export $1=\"\$CHALKWORK_USER_$1\"; else unset $1; fi
    unset CHALKWORK_USER_$1"
}
