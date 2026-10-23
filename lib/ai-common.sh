#!/bin/bash
# ai-common.sh - Shared functions for git-ai tools

die() {
  echo "${0##*/}: $*" >&2
  exit 1
}

# Directory holding the bundled Python package (prompts, CLIs, data files).
# Defaults to the repo/symlink layout (sibling of lib/); the pip launcher
# overrides it via env to point at the installed git_ai package.
GIT_AI_PKG_DIR="${GIT_AI_PKG_DIR:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../python/git_ai}"
[[ -d "$GIT_AI_PKG_DIR" ]] || die "GIT_AI_PKG_DIR not found: $GIT_AI_PKG_DIR (use the git-ai console script, not _sh/bin/git-ai directly)"

# python3 backs response formatting and every provider API call, so name a
# missing interpreter up front instead of surfacing it as "command not found"
# from inside a pipeline after the LLM has already been billed.
require_python() {
  command -v "${GIT_AI_PYTHON:-python3}" >/dev/null 2>&1 ||
    die "requires python3 (set GIT_AI_PYTHON to point at an interpreter)"
}

# _curl_cfg VAR FORMAT [ARG...] — write printf FORMAT to a fresh curl config
# file and store its path in VAR. Used to keep a key out of argv, where `ps`
# would show it. The caller registers cleanup with _rm_on_exit: this cannot do
# it, since a $(...) call's trap would die with its subshell.
_curl_cfg() {
  local __var="$1" __fmt="$2" __cfg
  shift 2
  __cfg=$(mktemp "${TMPDIR:-/tmp}/git-ai-curl.XXXXXX") || return 1
  # shellcheck disable=SC2059 # FORMAT is a literal from our own callers
  if ! printf "$__fmt" "$@" >"$__cfg"; then
    rm -f "$__cfg"
    return 1
  fi
  printf -v "$__var" '%s' "$__cfg"
}

# _rm_on_exit CMD — run CMD on exit, including a terminal hangup (bash skips
# the EXIT trap when SIGHUP kills a non-interactive shell).
_rm_on_exit() {
  # shellcheck disable=SC2064 # CMD is the caller's single-quoted string; expands when trapped
  trap "$1" EXIT
  trap 'exit 129' HUP
}

# Print $1 with leading/trailing whitespace stripped.
_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  printf '%s' "${s%"${s##*[![:space:]]}"}"
}

get_last_choice() {
  local key="$1"
  local fallback="$2"
  local git_dir
  git_dir=$(git rev-parse --git-dir 2>/dev/null) || { printf '%s\n' "$fallback"; return 0; }
  local state_file="${git_dir}/${key}"
  if [[ -r "$state_file" ]]; then
    local stored
    stored=$(<"$state_file")
    stored="${stored%"${stored##*[![:space:]]}"}"
    printf '%s\n' "$stored"
    return 0
  fi
  printf '%s\n' "$fallback"
}

save_last_choice() {
  local key="$1"
  local value="$2"
  local git_dir
  git_dir=$(git rev-parse --git-dir 2>/dev/null) || return 0
  printf '%s\n' "$value" >"${git_dir}/${key}" 2>/dev/null || true
}

get_last_provider() {
  # Accept any stored token, then validate with provider_is_valid so that
  # profile-qualified providers (e.g. vertex-anthropic@proj-a) round-trip.
  local stored
  stored=$(get_last_choice "${1}-last-provider" "${2:-}")
  if [[ -n "$stored" ]] && provider_is_valid "$stored"; then
    printf '%s\n' "$stored"
  else
    printf '%s\n' "${2:-}"
  fi
}

save_last_provider() {
  save_last_choice "${1}-last-provider" "$2"
}

# Models are no longer a fixed catalog, so any saved id round-trips; the provider API validates the model at call time.
get_last_model() {
  local tool_name="$1"
  local provider="$2"
  local fallback="$3"
  get_last_choice "${tool_name}-${provider}-last-model" "$fallback"
}

save_last_model() {
  save_last_choice "${1}-${2}-last-model" "$3"
}

save_last_message() {
  save_last_choice "${1}-last-message" "$2"
}

# .git/{tool}-choice-history — newline-separated LRU of picks (most recent first).
CHOICE_HISTORY_CAP=30

get_choice_history() {
  local tool_name="$1"
  local git_dir
  git_dir=$(git rev-parse --git-dir 2>/dev/null) || return 0
  local history_file="${git_dir}/${tool_name}-choice-history"
  [[ -r "$history_file" ]] || return 0
  cat "$history_file"
}

push_choice_history() {
  local tool_name="$1"
  local value="$2"
  [[ -n "$value" ]] || return 0
  local git_dir
  git_dir=$(git rev-parse --git-dir 2>/dev/null) || return 0
  local history_file="${git_dir}/${tool_name}-choice-history"

  local -a entries=("$value")
  if [[ -r "$history_file" ]]; then
    local existing
    while IFS= read -r existing; do
      [[ -n "$existing" && "$existing" != "$value" ]] || continue
      entries+=("$existing")
      [[ ${#entries[@]} -lt $CHOICE_HISTORY_CAP ]] || break
    done <"$history_file"
  fi
  printf '%s\n' "${entries[@]}" >"$history_file" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Submodules — ai-common.sh is the umbrella entry point; sourcing it pulls in
# the full helper surface. Split out for file size / readability.
# ---------------------------------------------------------------------------
_AI_COMMON_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck source=lib/auth.sh
source "${_AI_COMMON_DIR}/auth.sh"
# shellcheck source=lib/discovery.sh
source "${_AI_COMMON_DIR}/discovery.sh"
# shellcheck source=lib/config.sh
source "${_AI_COMMON_DIR}/config.sh"
# shellcheck source=lib/provider.sh
source "${_AI_COMMON_DIR}/provider.sh"
