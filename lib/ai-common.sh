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

# Built-in lockfile patterns excluded from diffs by default.
GIT_AI_DEFAULT_EXCLUDES_FILE="${GIT_AI_PKG_DIR}/default-excludes.txt"
GIT_AI_DEFAULT_EXCLUDES=()
if [[ ! -r "$GIT_AI_DEFAULT_EXCLUDES_FILE" ]]; then
  die "missing default excludes file: $GIT_AI_DEFAULT_EXCLUDES_FILE"
fi
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
  GIT_AI_DEFAULT_EXCLUDES+=("$line")
done <"$GIT_AI_DEFAULT_EXCLUDES_FILE"

# load_git_ai_ignore <repo_root>
# Print active exclude patterns (defaults + .git-ai-ignore additions, minus
# negations marked with `!`), one per line. Order: defaults first, then
# additions in file order. Duplicates are dropped.
load_git_ai_ignore() {
  local repo_root="$1"
  local ignore_file="${repo_root}/.git-ai-ignore"
  local -a additions=()
  local -a negations=()
  local line trimmed neg
  if [[ -r "$ignore_file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      trimmed="${line#"${line%%[![:space:]]*}"}"
      trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
      [[ -z "$trimmed" || "${trimmed:0:1}" == "#" ]] && continue
      if [[ "${trimmed:0:1}" == "!" ]]; then
        neg="${trimmed:1}"
        neg="${neg#"${neg%%[![:space:]]*}"}"
        neg="${neg%"${neg##*[![:space:]]}"}"
        [[ -n "$neg" ]] && negations+=("$neg")
      else
        additions+=("$trimmed")
      fi
    done <"$ignore_file"
  fi

  local emitted=$'\n'
  local p n is_negated
  for p in "${GIT_AI_DEFAULT_EXCLUDES[@]}" ${additions[@]+"${additions[@]}"}; do
    is_negated=false
    for n in ${negations[@]+"${negations[@]}"}; do
      [[ "$n" == "$p" ]] && { is_negated=true; break; }
    done
    [[ "$is_negated" == "true" ]] && continue
    case "$emitted" in
      *$'\n'"$p"$'\n'*) continue ;;
    esac
    printf '%s\n' "$p"
    emitted+="$p"$'\n'
  done
}

# load_git_ai_instructions <repo_root>
# Print the trimmed contents of the repo-root .git-ai-instructions file, or
# nothing when it is absent/empty. Free-form repo-local conventions (commit
# scopes, type-classification overrides) surfaced to the model as authoritative.
load_git_ai_instructions() {
  local repo_root="$1"
  local instr_file="${repo_root}/.git-ai-instructions"
  [[ -r "$instr_file" ]] || return 0
  # Mirror the Python path (_instructions.py): skip non-UTF-8 files instead of
  # injecting garbled bytes into the prompt. Only enforced when iconv is
  # available; degrade to a raw read otherwise.
  if command -v iconv >/dev/null 2>&1; then
    iconv -f UTF-8 -t UTF-8 "$instr_file" >/dev/null 2>&1 || return 0
  fi
  local content
  content=$(<"$instr_file")
  # Trim leading/trailing whitespace; emit nothing when effectively empty.
  content="${content#"${content%%[![:space:]]*}"}"
  content="${content%"${content##*[![:space:]]}"}"
  [[ -n "$content" ]] && printf '%s\n' "$content"
  return 0
}

# build_pathspec_excludes [patterns...]
# Print repo-root pathspec args for `git diff` (one per line), or nothing
# when no patterns are given. Caller splats the result into the git command.
build_pathspec_excludes() {
  [[ $# -gt 0 ]] || return 0
  printf -- '--\n'
  printf ':/\n'
  local p
  for p in "$@"; do
    printf ':(top,exclude,glob)**/%s\n' "$p"
  done
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

strip_fences() {
  perl -0pe '
    s/^[ \t]*```.*\n//mg;
    s/^[ \t]*`+[ \t]*\n//mg;
    s/\A(?:[ \t]*\n)+//;
    s/\A[ \t]*(`+)([^`\n]+)\1[ \t]*$/$2/m;
    s/(?:\n[ \t]*)+\z/\n/s;
  '
}

# Slice title/body out of sentinel-delimited PR output read from stdin. The PR
# prompts wrap their answer in ===TITLE=== / ===BODY=== line markers so any
# preamble, reasoning, or char-count chatter outside the markers is discarded;
# prints "title\n\nbody". Passes the input through unchanged when the markers
# are absent or malformed (older or non-compliant models). Mirrors
# python/git_ai/_generate.py:_extract_pr_sections.
extract_pr_output() {
  perl -0777 -ne '
    if (/^===TITLE===[ \t]*\n(.*?)\n===BODY===[ \t]*\n(.*)\z/ms) {
      my ($t, $b) = ($1, $2);
      $t =~ s/\A\s+//; $t =~ s/\s+\z//;
      $b =~ s/\A\s+//; $b =~ s/\s+\z//;
      if (length $t) {
        print length($b) ? "$t\n\n$b\n" : "$t\n";
        next;
      }
    }
    print;
  '
}

# Slice the commit message out of a model response read from stdin, discarding
# any preamble. Reasoning models emit their type-choice rationale ahead of the
# message, which otherwise lands as the subject line. Prefers everything after
# the ===COMMIT=== marker the commit prompt asks for; falls back to the first
# Conventional Commits subject line onward for models that drop the marker, and
# passes the input through unchanged when neither is present. Mirrors
# python/git_ai/_generate.py:_extract_commit_message.
extract_commit_output() {
  perl -0777 -ne '
    if (/^===COMMIT===[ \t]*\n(.*)\z/ms) {
      my $m = $1;
      $m =~ s/\A\s+//; $m =~ s/\s+\z//;
      if (length $m) { print "$m\n"; next; }
    }
    if (/^((?:feat|fix|refactor|build|chore|docs|style|test|perf|ci|revert)(?:\([^)]*\))?!?: \S.*)\z/ms) {
      my $m = $1;
      $m =~ s/\s+\z//;
      print "$m\n";
      next;
    }
    print;
  '
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
