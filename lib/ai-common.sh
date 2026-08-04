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

# check_diff_size_or_die <diff>
# Abort with a "Largest changed files" hint when the diff exceeds
# ${GIT_AI_MAX_DIFF_BYTES:-900000}. Set GIT_AI_MAX_DIFF_BYTES=0 to disable.
check_diff_size_or_die() {
  local diff="$1"
  local limit="${GIT_AI_MAX_DIFF_BYTES:-900000}"
  [[ "$limit" =~ ^[0-9]+$ ]] || limit=900000
  [[ "$limit" -gt 0 ]] || return 0
  local size
  size=$(printf '%s' "$diff" | wc -c | tr -d ' ')
  [[ "$size" -le "$limit" ]] && return 0

  local top
  top=$(printf '%s' "$diff" | awk '
    function flush() { if (path != "") { printf "%d\t%s\n", ins+del, path } }
    /^diff --git a\// {
      flush()
      ins=0; del=0
      if (match($0, / b\/.+$/)) {
        path=substr($0, RSTART+3)
      } else { path="" }
      next
    }
    /^\+\+\+/ || /^---/ { next }
    /^\+/ { ins++; next }
    /^-/  { del++; next }
    END   { flush() }
  ' | sort -t$'\t' -k1,1nr | head -5 | awk -F'\t' '{ printf "   %6d lines  %s\n", $1, $2 }')

  {
    printf 'git-ai: diff is %s bytes, exceeds limit (%s).\n' "$size" "$limit"
    printf 'Largest changed files:\n'
    [[ -n "$top" ]] && printf '%s\n' "$top"
    printf 'Add patterns to .git-ai-ignore (repo root) to skip them, unstage them, or raise GIT_AI_MAX_DIFF_BYTES.\n'
  } >&2
  exit 1
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
  local valid="$3"
  local git_dir
  git_dir=$(git rev-parse --git-dir 2>/dev/null) || { printf '%s\n' "$fallback"; return 0; }
  local state_file="${git_dir}/${key}"
  if [[ -r "$state_file" ]]; then
    local stored
    stored=$(<"$state_file")
    stored="${stored%"${stored##*[![:space:]]}"}"
    # A "*" valid set accepts any stored value (caller validates separately —
    # e.g. profile-qualified provider tokens that no static alternation lists).
    if [[ "$valid" == "*" ]]; then
      printf '%s\n' "$stored"
      return 0
    fi
    if [[ "|${valid}|" == *"|${stored}|"* ]]; then
      printf '%s\n' "$stored"
      return 0
    fi
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
  stored=$(get_last_choice "${1}-last-provider" "${2:-}" "*")
  if [[ -n "$stored" ]] && provider_is_valid "$stored"; then
    printf '%s\n' "$stored"
  else
    printf '%s\n' "${2:-}"
  fi
}

save_last_provider() {
  save_last_choice "${1}-last-provider" "$2"
}

# Models are no longer a fixed catalog, so any saved id round-trips ("*" accepts
# the stored value as-is). The provider API validates the model at call time.
get_last_model() {
  local tool_name="$1"
  local provider="$2"
  local fallback="$3"
  get_last_choice "${tool_name}-${provider}-last-model" "$fallback" "*"
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
