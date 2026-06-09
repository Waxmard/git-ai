#!/bin/bash
# ai-common.sh - Shared functions for git-ai tools

die() {
  echo "${0##*/}: $*" >&2
  exit 1
}

# Built-in lockfile patterns excluded from diffs by default.
GIT_AI_DEFAULT_EXCLUDES_FILE="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../python/git_ai/default-excludes.txt"
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
    s/(?:\n[ \t]*)+\z/\n/s;
  '
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

load_google_env() {
  if [[ -n "${GOOGLE_CLOUD_PROJECT:-}" ]]; then
    export GOOGLE_CLOUD_PROJECT
    export GOOGLE_VERTEX_PROJECT="${GOOGLE_VERTEX_PROJECT:-$GOOGLE_CLOUD_PROJECT}"
  fi

  if [[ -n "${GOOGLE_CLOUD_LOCATION:-}" ]]; then
    export GOOGLE_CLOUD_LOCATION
    export VERTEX_LOCATION="${VERTEX_LOCATION:-$GOOGLE_CLOUD_LOCATION}"
    export GOOGLE_VERTEX_LOCATION="${GOOGLE_VERTEX_LOCATION:-$GOOGLE_CLOUD_LOCATION}"
  elif [[ -n "${VERTEX_LOCATION:-}" ]]; then
    export VERTEX_LOCATION
    export GOOGLE_CLOUD_LOCATION="${GOOGLE_CLOUD_LOCATION:-$VERTEX_LOCATION}"
    export GOOGLE_VERTEX_LOCATION="${GOOGLE_VERTEX_LOCATION:-$VERTEX_LOCATION}"
  elif [[ -n "${GOOGLE_VERTEX_LOCATION:-}" ]]; then
    export GOOGLE_VERTEX_LOCATION
    export GOOGLE_CLOUD_LOCATION="${GOOGLE_CLOUD_LOCATION:-$GOOGLE_VERTEX_LOCATION}"
    export VERTEX_LOCATION="${VERTEX_LOCATION:-$GOOGLE_VERTEX_LOCATION}"
  fi

  if [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]]; then
    export GOOGLE_APPLICATION_CREDENTIALS
  fi
}

resolve_gemini_bin() {
  if [[ -n "${GEMINI_BIN:-}" && -x "$GEMINI_BIN" ]]; then
    printf '%s\n' "$GEMINI_BIN"
    return 0
  fi

  if [[ -d "$HOME/.nvm/versions/node" ]]; then
    local nvm_bin
    for nvm_bin in "$HOME/.nvm/versions/node"/*/bin/gemini; do
      [[ -f "$nvm_bin" && -x "$nvm_bin" ]] && { printf '%s\n' "$nvm_bin"; return 0; }
    done
  fi

  local candidate
  for candidate in "$HOME/.local/bin/gemini" "/opt/homebrew/bin/gemini" "/usr/local/bin/gemini"; do
    [[ -x "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
  done

  if command -v gemini >/dev/null 2>&1; then
    command -v gemini
    return 0
  fi

  return 1
}

# resolve_api_key SERVICE ENVVAR
# Resolve a provider API key, first hit wins: the named env var, then the OS
# secret store keyed on SERVICE (macOS Keychain, libsecret, pass, KDE Wallet).
# Prints the key on stdout; returns non-zero when nothing is found.
resolve_api_key() {
  local service="$1"
  local envvar="$2"
  local keychain_account
  local key
  local env_val="${!envvar:-}"

  if [[ -n "$env_val" ]]; then
    printf '%s\n' "$env_val"
    return 0
  fi

  # macOS Keychain
  if command -v security >/dev/null 2>&1; then
    keychain_account="${USER:-${LOGNAME:-$(id -un 2>/dev/null)}}"
    if [[ -n "$keychain_account" ]]; then
      key=$(security find-generic-password -a "$keychain_account" -s "$service" -w 2>/dev/null) && [[ -n "$key" ]] && {
        printf '%s\n' "$key"
        return 0
      }
    fi
    key=$(security find-generic-password -s "$service" -w 2>/dev/null) && [[ -n "$key" ]] && {
      printf '%s\n' "$key"
      return 0
    }
  fi

  # Linux: libsecret / GNOME Keyring
  if command -v secret-tool >/dev/null 2>&1; then
    key=$(secret-tool lookup service "$service" 2>/dev/null) && [[ -n "$key" ]] && {
      printf '%s\n' "$key"
      return 0
    }
  fi

  # Linux: pass (password-store)
  if command -v pass >/dev/null 2>&1; then
    key=$(pass show "$service" 2>/dev/null) && [[ -n "$key" ]] && {
      printf '%s\n' "$key"
      return 0
    }
  fi

  # Linux: KDE Wallet
  if command -v kwallet-query >/dev/null 2>&1; then
    key=$(kwallet-query kdewallet -r "$service" 2>/dev/null) && [[ -n "$key" ]] && {
      printf '%s\n' "$key"
      return 0
    }
  fi

  return 1
}

# Gemini key resolution is just the generic resolver under the gemini service.
resolve_gemini_api_key() {
  resolve_api_key gemini-api-key GEMINI_API_KEY
}

# store_api_key SERVICE KEY
# Persist KEY in the OS secret store under SERVICE, using whichever backend is
# available — mirroring the read order in resolve_api_key so the key round-trips.
# Returns non-zero when no secret-store backend is installed (caller should then
# offer the shell-rc fallback).
store_api_key() {
  local service="$1" key="$2" account
  account="${USER:-${LOGNAME:-$(id -un 2>/dev/null)}}"

  if command -v security >/dev/null 2>&1; then
    security add-generic-password -U -a "$account" -s "$service" -w "$key" 2>/dev/null && return 0
  fi
  if command -v secret-tool >/dev/null 2>&1; then
    printf '%s' "$key" | secret-tool store --label="$service" service "$service" 2>/dev/null && return 0
  fi
  if command -v pass >/dev/null 2>&1; then
    printf '%s\n' "$key" | pass insert -m -f "$service" >/dev/null 2>&1 && return 0
  fi
  return 1
}

# shell_rc_path [SHELL]
# Print the rc file to append an env export to, inferred from SHELL (or the
# given shell basename).
# shellcheck disable=SC2120  # SHELL arg is optional; persist_key_to_rc omits it, tests pass it
shell_rc_path() {
  local sh="${1:-${SHELL##*/}}"
  case "$sh" in
    zsh)  printf '%s\n' "${ZDOTDIR:-$HOME}/.zshrc" ;;
    bash) printf '%s\n' "$HOME/.bashrc" ;;
    fish) printf '%s\n' "$HOME/.config/fish/config.fish" ;;
    *)    printf '%s\n' "$HOME/.profile" ;;
  esac
}

# format_key_export ENVVAR KEY [SHELL]
# Print the shell line that exports ENVVAR=KEY, in the syntax of the target
# shell (fish uses `set -gx`; everything else POSIX `export`).
format_key_export() {
  local envvar="$1" key="$2" sh="${3:-${SHELL##*/}}"
  case "$sh" in
    fish) printf "set -gx %s '%s'\n" "$envvar" "$key" ;;
    *)    printf "export %s='%s'\n" "$envvar" "$key" ;;
  esac
}

# persist_key_to_rc ENVVAR KEY
# Append an env export for KEY to the user's shell rc. Prints the rc path on
# success. The key lands in plaintext — callers should warn the user.
persist_key_to_rc() {
  local envvar="$1" key="$2" rc line
  # shellcheck disable=SC2119  # intentional: no SHELL arg, use $SHELL default
  rc=$(shell_rc_path) || return 1
  line=$(format_key_export "$envvar" "$key")
  mkdir -p "$(dirname "$rc")" 2>/dev/null || true
  printf '\n# Added by git-ai setup\n%s\n' "$line" >>"$rc" || return 1
  printf '%s\n' "$rc"
}

# provider_ready PROVIDER
# True when PROVIDER could authenticate right now, mirroring run_provider's
# per-provider preconditions. On failure, prints a one-line reason to stderr.
# Used by the setup wizard's status table; run_provider's own checks defer to
# the same primitives (resolve_api_key, _vertex_has_auth, command -v).
provider_ready() {
  local provider="${1:-}"
  case ${provider%%@*} in
    claude-code)
      command -v claude >/dev/null 2>&1 && return 0
      printf 'Claude Code CLI not installed\n' >&2 ;;
    codex)
      command -v codex >/dev/null 2>&1 && return 0
      printf 'Codex CLI not installed\n' >&2 ;;
    anthropic-api)
      resolve_api_key anthropic-api-key ANTHROPIC_API_KEY >/dev/null 2>&1 && return 0
      printf 'ANTHROPIC_API_KEY not set (env or keychain)\n' >&2 ;;
    openai-api)
      resolve_api_key openai-api-key OPENAI_API_KEY >/dev/null 2>&1 && return 0
      printf 'OPENAI_API_KEY not set (env or keychain)\n' >&2 ;;
    gemini-api)
      resolve_gemini_api_key >/dev/null 2>&1 && return 0
      printf 'Gemini auth not found (GEMINI_API_KEY or keychain)\n' >&2 ;;
    vertex|vertex-gemini|vertex-anthropic)
      local account project
      account=$(vertex_resolve "$provider" account)
      if ! _vertex_has_auth "$account"; then
        printf 'Vertex auth not found (gcloud ADC, account=, or credentials=)\n' >&2
        return 1
      fi
      project=$(vertex_resolve "$provider" project)
      project="${project:-${GOOGLE_VERTEX_PROJECT:-${GOOGLE_CLOUD_PROJECT:-}}}"
      [[ -n "$project" ]] && return 0
      printf 'Vertex project not set (project= or GOOGLE_CLOUD_PROJECT)\n' >&2 ;;
    *)
      printf 'unknown provider: %s\n' "$provider" >&2 ;;
  esac
  return 1
}

_gemini_has_adc() {
  if [[ -n "$(_vertex_access_token)" ]]; then
    return 0
  fi
  return 1
}

# _vertex_has_auth [ACCOUNT]
# True when a Vertex access token can be minted for the given auth path. With
# no ACCOUNT this is ADC-only (same guard as _gemini_has_adc); with an ACCOUNT
# it validates the per-account user credential instead.
_vertex_has_auth() {
  [[ -n "$(_vertex_access_token "${1:-}")" ]]
}

# _vertex_access_token [ACCOUNT]
# With no ACCOUNT, mint an Application Default Credentials token (honours
# GOOGLE_APPLICATION_CREDENTIALS when exported). With ACCOUNT, mint a token for
# that specific gcloud-authed user account, enabling multi-account setups.
_vertex_access_token() {
  command -v gcloud >/dev/null 2>&1 || return 1
  local account="${1:-}"
  if [[ -n "$account" ]]; then
    gcloud auth print-access-token --account="$account" 2>/dev/null
  else
    gcloud auth application-default print-access-token 2>/dev/null
  fi
}

provider_display_name() {
  local base="${1%%@*}" profile="" name=""
  case $1 in *@*) profile="${1#*@}" ;; esac
  case $base in
    # One user-facing "Vertex AI": the gemini/anthropic split is an internal
    # routing detail inferred from the model id, never shown to the user.
    vertex | vertex-gemini | vertex-anthropic) name="Vertex AI" ;;
    gemini-api)    name="Gemini API" ;;
    claude-code)   name="Claude Code" ;;
    anthropic-api) name="Anthropic API" ;;
    codex)         name="Codex CLI" ;;
    openai-api)    name="OpenAI API" ;;
    last)          name="Reuse last message" ;;
    *) return 0 ;;
  esac
  if [[ -n "$profile" ]]; then
    printf '%s [%s]\n' "$name" "$profile"
  else
    printf '%s\n' "$name"
  fi
}

# Curated recommended-model defaults live in a dedicated DATA file at the repo
# root so model bumps read as data changes, not code changes (commits touching
# only that file are routine "chore: bump recommended X model" updates).
GIT_AI_RECOMMENDED_MODELS_FILE="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../recommended-models.conf"

# recommended_model PROVIDER
# Print the recommended model id for PROVIDER's family, read from
# recommended-models.conf (`family = model-id` lines). Used by the setup
# wizard's fast path so a new (often non-technical) user gets a sensible pin
# without having to choose one. Empty output means "no recommendation" (caller
# leaves the model unpinned). Suggestions only: discovery still feeds the
# picker and any id remains overridable — this is intentionally a single
# curated default per family, not the (deliberately non-existent) full catalog.
recommended_model() {
  local family
  case "${1%%@*}" in
    claude-code | anthropic-api | vertex-anthropic) family=anthropic ;;
    gemini-api | vertex-gemini) family=google ;;
    openai-api | codex) family=openai ;;
    *) return 0 ;;
  esac

  [[ -r "$GIT_AI_RECOMMENDED_MODELS_FILE" ]] || return 0
  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *=* && "${line#"${line%%[![:space:]]*}"}" != \#* ]] || continue
    key="${line%%=*}"
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    [[ "$key" == "$family" ]] || continue
    val="${line#*=}"
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    [[ -n "$val" ]] && printf '%s\n' "$val"
    return 0
  done <"$GIT_AI_RECOMMENDED_MODELS_FILE"
}

provider_is_valid() {
  # Profile-qualified tokens (base@profile) are only valid for vertex providers,
  # which are the only ones that read per-profile account/project config.
  case $1 in
    *@*)
      case ${1%%@*} in
        vertex-gemini|vertex-anthropic) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    vertex-gemini|vertex-anthropic|gemini-api|claude-code|anthropic-api|codex|openai-api|last) return 0 ;;
    *) return 1 ;;
  esac
}

provider_family() {
  case ${1%%@*} in
    vertex-gemini|gemini-api) printf '%s\n' "gemini" ;;
    vertex-anthropic|claude-code|anthropic-api) printf '%s\n' "claude" ;;
    codex|openai-api) printf '%s\n' "openai" ;;
    *) return 1 ;;
  esac
}

# provider_key_meta PROVIDER
# For an API-key provider, print "SERVICE ENVVAR" (the keychain service name and
# the environment variable resolve_api_key consults). Returns non-zero for
# providers that don't authenticate via a stored key (CLI / vertex).
provider_key_meta() {
  case ${1%%@*} in
    anthropic-api) printf 'anthropic-api-key ANTHROPIC_API_KEY\n' ;;
    openai-api)    printf 'openai-api-key OPENAI_API_KEY\n' ;;
    gemini-api)    printf 'gemini-api-key GEMINI_API_KEY\n' ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Model discovery (live, cached)
# ---------------------------------------------------------------------------
# Model lists are fetched from each provider's own API rather than hardcoded, so
# new models appear without a git-ai release. Results are cached to disk with a
# TTL (network calls are slow; don't hit the API on every commit). Discovery is
# best-effort: providers that can't be listed (the CLIs with no list endpoint,
# or any provider whose creds aren't set yet) yield nothing, and every picker
# falls back to free-text entry. Nothing here gates validation — resolve_model
# accepts any model ID; the provider API is the real validator.

_models_cache_dir() {
  printf '%s/git-ai/models-cache\n' "${XDG_CONFIG_HOME:-$HOME/.config}"
}

# Per-provider cache file. Profile-qualified tokens (vertex-x@profile) get their
# own file so different projects don't clobber each other's catalogs.
_models_cache_path() {
  local safe="${1//[^a-zA-Z0-9._@-]/_}"
  printf '%s/%s.list\n' "$(_models_cache_dir)" "$safe"
}

# discover_models PROVIDER [--refresh]
# Print discovered model IDs (one per line). Serves a fresh on-disk cache when
# present, otherwise fetches, caches, and prints. On a fetch failure, serves a
# stale cache if one exists. Empty output + non-zero return when nothing can be
# discovered, so callers know to rely on free-text entry. TTL in minutes via
# GIT_AI_MODELS_TTL_MIN (default 1440 = 24h); --refresh forces a re-fetch.
discover_models() {
  local provider="$1" refresh="${2:-}"
  local cache ttl="${GIT_AI_MODELS_TTL_MIN:-1440}"
  cache=$(_models_cache_path "$provider")

  if [[ "$refresh" != "--refresh" && -s "$cache" ]]; then
    # `find -mmin +TTL` prints the file only when it is OLDER than TTL minutes;
    # empty output means the cache is still fresh.
    if [[ -z "$(find "$cache" -mmin +"$ttl" 2>/dev/null)" ]]; then
      # $(<file) reads in-shell — this cache-hit path runs once per provider
      # on every picker open, so skip the cat fork+exec.
      printf '%s\n' "$(<"$cache")"
      return 0
    fi
  fi

  # Authed provider API first (reflects the account's real access); fall back to
  # the keyless models.dev catalog when there's no key/CLI list (covers the CLI
  # providers, and any provider whose creds aren't set up).
  local fetched
  fetched=$(_fetch_models "$provider" 2>/dev/null)
  [[ -n "$fetched" ]] || fetched=$(_fetch_models_modelsdev "$provider" 2>/dev/null)
  if [[ -n "$fetched" ]]; then
    mkdir -p "$(_models_cache_dir)" 2>/dev/null || true
    printf '%s\n' "$fetched" >"$cache" 2>/dev/null || true
    printf '%s\n' "$fetched"
    return 0
  fi

  # Fetch failed (offline, no creds, API error) — serve any stale cache.
  [[ -s "$cache" ]] && { printf '%s\n' "$(<"$cache")"; return 0; }
  return 1
}

# models.dev → git-ai family. Prints "MODELS_DEV_KEY<TAB>FAMILY_PREFIX"; the
# prefix narrows the (noisy) catalog to the right family (empty for openai, which
# is matched by a gpt/o-number regex instead). Returns non-zero for unmapped.
_models_dev_key() {
  case ${1%%@*} in
    gemini-api | vertex-gemini)                printf 'google\tgemini\n' ;;
    anthropic-api | claude-code | vertex-anthropic) printf 'anthropic\tclaude\n' ;;
    openai-api | codex)                        printf 'openai\t\n' ;;
    *) return 1 ;;
  esac
}

# Keyless model list from the public models.dev catalog (no auth). The whole
# api.json is cached once (it covers every provider); per-call we extract the
# mapped provider's models and filter to text-generation ids.
_fetch_models_modelsdev() {
  local provider="$1" meta mdkey fam cache_json ttl tmp
  meta=$(_models_dev_key "$provider") || return 1
  IFS=$'\t' read -r mdkey fam <<<"$meta"
  cache_json="$(_models_cache_dir)/_modelsdev.json"
  ttl="${GIT_AI_MODELS_TTL_MIN:-1440}"

  if [[ ! -s "$cache_json" || -n "$(find "$cache_json" -mmin +"$ttl" 2>/dev/null)" ]]; then
    tmp=$(mktemp "${TMPDIR:-/tmp}/git-ai-md.XXXXXX") || return 1
    if curl -sf "https://models.dev/api.json" -o "$tmp"; then
      mkdir -p "$(_models_cache_dir)" 2>/dev/null || true
      mv "$tmp" "$cache_json" 2>/dev/null || rm -f "$tmp"
    else
      rm -f "$tmp"
    fi
  fi
  [[ -s "$cache_json" ]] || return 1

  GIT_AI_MDKEY="$mdkey" GIT_AI_FAM="$fam" GIT_AI_CACHE="$cache_json" python3 -c '
import json, os, re
SKIP = ("embedding", "-tts", "tts", "-image", "image", "-audio", "audio",
        "-live", "computer-use", "native-audio", "-guard", "gemma")
d = json.load(open(os.environ["GIT_AI_CACHE"]))
fam = os.environ["GIT_AI_FAM"]
out = []
for mid in d.get(os.environ["GIT_AI_MDKEY"], {}).get("models", {}):
    low = mid.lower()
    if any(s in low for s in SKIP):
        continue
    if fam:
        if not low.startswith(fam):
            continue
    elif not re.match(r"^(gpt|o[0-9])", low):
        continue
    out.append(mid)
for m in sorted(set(out), reverse=True):
    print(m)
' 2>/dev/null
}

# Dispatch a provider to its fetch helper. The CLIs have no list endpoint, so
# they borrow the matching API's catalog when a key is configured.
_fetch_models() {
  case ${1%%@*} in
    gemini-api)       _fetch_models_gemini_api ;;
    vertex-gemini)    _fetch_models_vertex "$1" google ;;
    vertex-anthropic) _fetch_models_vertex "$1" anthropic ;;
    anthropic-api)    _fetch_models_anthropic_api ;;
    openai-api)       _fetch_models_openai_api ;;
    claude-code)      _fetch_models_anthropic_api ;;
    codex)            _fetch_models_openai_api ;;
    *) return 1 ;;
  esac
}

# Gemini (AI Studio) — GET /v1beta/models, filtered to generateContent models.
# The API key goes in the URL, so the whole URL lives in the curl config file
# rather than argv (keeps the key out of `ps`).
_fetch_models_gemini_api() {
  local key cfg resp st
  key=$(resolve_gemini_api_key) && [[ -n "$key" ]] || return 1
  cfg=$(mktemp "${TMPDIR:-/tmp}/git-ai-curl.XXXXXX") || return 1
  trap 'rm -f "$cfg"' EXIT
  printf 'url = "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000&key=%s"\n' "$key" >"$cfg"
  resp=$(curl -sf -K "$cfg")
  st=$?
  rm -f "$cfg"
  [[ $st -eq 0 ]] || return 1
  GIT_AI_JSON="$resp" python3 -c '
import json, os
for m in json.loads(os.environ["GIT_AI_JSON"]).get("models", []):
    if "generateContent" in m.get("supportedGenerationMethods", []):
        name = m.get("baseModelId") or m.get("name", "").split("/")[-1]
        if name:
            print(name)
' 2>/dev/null
}

# Anthropic — GET /v1/models (newest-first). Key in a header via curl config.
_fetch_models_anthropic_api() {
  local key cfg resp st
  key=$(resolve_api_key anthropic-api-key ANTHROPIC_API_KEY) && [[ -n "$key" ]] || return 1
  cfg=$(mktemp "${TMPDIR:-/tmp}/git-ai-curl.XXXXXX") || return 1
  trap 'rm -f "$cfg"' EXIT
  printf 'header = "x-api-key: %s"\n' "$key" >"$cfg"
  resp=$(curl -sf -K "$cfg" -H "anthropic-version: 2023-06-01" \
    "https://api.anthropic.com/v1/models?limit=1000")
  st=$?
  rm -f "$cfg"
  [[ $st -eq 0 ]] || return 1
  GIT_AI_JSON="$resp" python3 -c '
import json, os
for m in json.loads(os.environ["GIT_AI_JSON"]).get("data", []):
    i = m.get("id")
    if i:
        print(i)
' 2>/dev/null
}

# OpenAI — GET /v1/models returns every model (embeddings, tts, …), so filter to
# chat-capable ids heuristically (gpt* / o<digit>*, minus known non-chat kinds).
_fetch_models_openai_api() {
  local key cfg resp st
  key=$(resolve_api_key openai-api-key OPENAI_API_KEY) && [[ -n "$key" ]] || return 1
  cfg=$(mktemp "${TMPDIR:-/tmp}/git-ai-curl.XXXXXX") || return 1
  trap 'rm -f "$cfg"' EXIT
  printf 'header = "Authorization: Bearer %s"\n' "$key" >"$cfg"
  resp=$(curl -sf -K "$cfg" "https://api.openai.com/v1/models")
  st=$?
  rm -f "$cfg"
  [[ $st -eq 0 ]] || return 1
  GIT_AI_JSON="$resp" python3 -c '
import json, os, re
NON_CHAT = ("embedding", "tts", "whisper", "audio", "image", "realtime",
            "dall-e", "moderation", "transcribe", "search", "similarity", "edit")
ids = [m.get("id", "") for m in json.loads(os.environ["GIT_AI_JSON"]).get("data", [])]
keep = [i for i in ids
        if re.match(r"^(gpt|o[0-9])", i) and not any(x in i for x in NON_CHAT)]
for i in sorted(set(keep), reverse=True):
    print(i)
' 2>/dev/null
}

# Vertex AI — GET {region}-aiplatform.../publishers/{google|anthropic}/models
# (Model Garden catalog). The model id is the last path segment of each
# publisherModels[].name, filtered to the family and to text-generation models
# (the catalog also lists embedding / image / tts / audio variants). User ADC
# requires a quota project (X-Goog-User-Project) or the API 403s; pageSize maxes
# at 300, and the catalog is paged. We walk up to a few pages.
_fetch_models_vertex() {
  local provider="$1" publisher="$2"
  local account region project token host cfg

  account=$(vertex_resolve "$provider" account)
  region=$(vertex_resolve "$provider" region)
  region="${region:-us-central1}"
  token=$(_vertex_access_token "$account") && [[ -n "$token" ]] || return 1

  # Quota project for the aiplatform API: the provider's own project, else the
  # gcloud default, else the first shared [vertex] projects entry. Any project
  # the caller can bill works — it does not affect the (global) catalog.
  project=$(vertex_resolve "$provider" project)
  if [[ -z "$project" ]] && command -v gcloud >/dev/null 2>&1; then
    project=$(gcloud config get-value project 2>/dev/null)
    [[ "$project" == "(unset)" ]] && project=""
  fi
  if [[ -z "$project" ]]; then
    local projlist
    projlist=$(vertex_config_value "vertex" projects)
    project=$(printf '%s' "$projlist" | tr ', ' '\n' | awk 'NF{print;exit}')
  fi
  [[ -n "$project" ]] || return 1

  [[ "$region" == "global" ]] && host="aiplatform.googleapis.com" \
                              || host="${region}-aiplatform.googleapis.com"
  cfg=$(mktemp "${TMPDIR:-/tmp}/git-ai-curl.XXXXXX") || return 1
  trap 'rm -f "$cfg"' EXIT
  printf 'header = "Authorization: Bearer %s"\nheader = "X-Goog-User-Project: %s"\n' \
    "$token" "$project" >"$cfg"

  local page_token="" url resp st page=0 names="" parsed
  while ((page < 5)); do
    url="https://${host}/v1beta1/publishers/${publisher}/models?pageSize=300"
    [[ -n "$page_token" ]] && url+="&pageToken=${page_token}"
    resp=$(curl -sf -K "$cfg" "$url")
    st=$?
    [[ $st -eq 0 ]] || break
    parsed=$(GIT_AI_PUB="$publisher" GIT_AI_JSON="$resp" python3 -c '
import json, os
prefix = "gemini" if os.environ["GIT_AI_PUB"] == "google" else "claude"
# Skip non-text variants the catalog mixes in.
SKIP = ("embedding", "-tts", "-image", "-audio", "-live", "computer-use",
        "native-audio", "-guard")
d = json.loads(os.environ["GIT_AI_JSON"])
# First line is the next page token (may be empty), then one model id per line.
print(d.get("nextPageToken", ""))
for m in d.get("publisherModels", []):
    name = m.get("name", "").split("/")[-1]
    if name.startswith(prefix) and not any(s in name for s in SKIP):
        print(name)
' 2>/dev/null) || break
    page_token=$(printf '%s\n' "$parsed" | head -n1)
    names+=$(printf '%s\n' "$parsed" | tail -n +2)$'\n'
    page=$((page + 1))
    [[ -n "$page_token" ]] || break
  done
  rm -f "$cfg"

  # De-dup, drop blanks, preserve order.
  printf '%s' "$names" | awk 'NF && !seen[$0]++'
}

# order_by_recent LAST ITEM...
# Prints items with LAST first, then remaining in original order.
order_by_recent() {
  local last="$1"
  shift
  printf '%s\n' "$last"
  for item in "$@"; do
    if [[ "$item" != "$last" ]]; then
      printf '%s\n' "$item"
    fi
  done
}

list_providers() {
  local tool_name="${1:-}"
  local all=(vertex-gemini vertex-anthropic gemini-api claude-code anthropic-api codex openai-api)

  if [[ -n "$tool_name" ]]; then
    local last ordered=()
    last=$(get_last_provider "$tool_name")
    if [[ -n "$last" ]]; then
      while IFS= read -r p; do ordered+=("$p"); done < <(order_by_recent "$last" "${all[@]}")
      all=("${ordered[@]}")
    fi

    local git_dir
    git_dir=$(git rev-parse --git-dir 2>/dev/null) && \
      [[ "$tool_name" == "commit" ]] && \
      [[ -r "${git_dir}/${tool_name}-last-message" ]] && \
      all=("${all[@]}" last)
  fi

  for p in "${all[@]}"; do
    printf '%s|%s\n' "$p" "$(provider_display_name "$p")"
  done
}

list_models() {
  local provider="${1:-}"
  local tool_name="${2:-}"
  local all=()

  if [[ "$provider" == "last" ]]; then
    printf '%s|%s\n' "n/a" "(reusing saved message)"
    return
  fi

  while IFS= read -r model; do
    [[ -n "$model" ]] && all+=("$model")
  done < <(discover_models "$provider")
  [[ ${#all[@]} -gt 0 ]] || return

  if [[ -n "$tool_name" ]]; then
    local last ordered=()
    last=$(get_last_model "$tool_name" "$provider" "${all[0]}")
    while IFS= read -r model; do ordered+=("$model"); done < <(order_by_recent "$last" "${all[@]}")
    all=("${ordered[@]}")
  fi

  for model in "${all[@]}"; do
    printf '%s|%s\n' "$model" "$model"
  done
}

# Path to user options config. XDG spec: $XDG_CONFIG_HOME/git-ai/options.conf,
# falling back to ~/.config/git-ai/options.conf.
user_options_path() {
  local xdg="${XDG_CONFIG_HOME:-$HOME/.config}"
  printf '%s/git-ai/options.conf\n' "$xdg"
}

# render_options_conf
# Read "provider:model" lines on stdin (one per enabled combo) and emit a
# git-ai options.conf body: one [provider] header per distinct provider in
# first-seen order, with its selected model IDs beneath (deduped, first-seen
# order). A provider line with no model still emits an empty header. The
# output round-trips through parse_user_options. Inverse of list_options.
# Bash 3.2 has no associative arrays, so providers are tracked in a first-seen
# order array and membership is checked against newline-delimited strings (the
# same technique list_options uses).
render_options_conf() {
  local line provider model
  local -a order=() lines=()
  local seen_providers=$'\n'

  while IFS= read -r line || [[ -n "$line" ]]; do
    lines+=("$line")
    provider="${line%%:*}"
    [[ -n "$provider" ]] || continue
    case "$seen_providers" in
      *$'\n'"$provider"$'\n'*) ;;
      *) order+=("$provider"); seen_providers+="${provider}"$'\n' ;;
    esac
  done

  printf '# git-ai options config — generated by "git-ai setup".\n'
  printf '# Edit freely: add/remove [provider] headers and model IDs.\n'
  printf '# See examples/options.conf for the full syntax (vertex profiles, etc.).\n'

  local p seen_models
  for p in "${order[@]}"; do
    printf '\n[%s]\n' "$p"
    seen_models=$'\n'
    for line in "${lines[@]}"; do
      [[ "$line" == *:* ]] || continue
      [[ "${line%%:*}" == "$p" ]] || continue
      model="${line#*:}"
      [[ -n "$model" ]] || continue
      case "$seen_models" in
        *$'\n'"$model"$'\n'*) ;;
        *) printf '%s\n' "$model"; seen_models+="${model}"$'\n' ;;
      esac
    done
  done
}

# The next four helpers are surgical, in-place editors over an existing
# options.conf: each reads the file on stdin and writes the edited file to
# stdout, touching only the targeted [provider] section and preserving every
# other line verbatim (comments, vertex `account=`/`projects=` settings, the
# shared [vertex] block, unrelated sections). This lets `git-ai setup` add or
# remove providers/models without ever rewriting — and losing — the rest.

# conf_section_providers
# Emit the section names that name a real provider (skips the shared [vertex]
# block and any non-provider headers), one per line, in file order.
conf_section_providers() {
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^\[(.+)\]$ ]] || continue
    provider_is_valid "${BASH_REMATCH[1]}" && printf '%s\n' "${BASH_REMATCH[1]}"
  done
}

# conf_remove_section PROVIDER
# Drop the [PROVIDER] header and its body (up to the next header / EOF).
conf_remove_section() {
  local target="$1" line in_target=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^\[(.+)\]$ ]]; then
      if [[ "${BASH_REMATCH[1]}" == "$target" ]]; then
        in_target=1
        continue
      fi
      in_target=0
    fi
    [[ $in_target -eq 1 ]] && continue
    printf '%s\n' "$line"
  done
}

# conf_add_section PROVIDER [MODEL...]
# Append a new [PROVIDER] section with the given models. Pure append — the
# existing file passes through untouched. Caller ensures PROVIDER isn't already
# present.
conf_add_section() {
  local provider="$1"
  shift
  cat
  printf '\n[%s]\n' "$provider"
  local m
  for m in "$@"; do
    printf '%s\n' "$m"
  done
}

# conf_set_section_models PROVIDER [MODEL...]
# Replace the model-ID lines inside [PROVIDER] with the given models, preserving
# the section's settings (key=value) and comments. A "model line" is any
# non-blank line in the section that is not a comment, a key=value setting, or a
# header — matching parse_user_options' notion of a model.
conf_set_section_models() {
  local target="$1"
  shift
  local line in_target=0 m
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^\[(.+)\]$ ]]; then
      in_target=0
      printf '%s\n' "$line"
      if [[ "${BASH_REMATCH[1]}" == "$target" ]]; then
        in_target=1
        for m in "$@"; do printf '%s\n' "$m"; done
      fi
      continue
    fi
    if [[ $in_target -eq 1 ]]; then
      # Keep settings / comments / blanks; drop the old model lines.
      if [[ -z "$line" || "$line" == \#* || "$line" == *=* ]]; then
        printf '%s\n' "$line"
      fi
      continue
    fi
    printf '%s\n' "$line"
  done
}

# conf_set_section_setting PROVIDER KEY VALUE
# Upsert a `KEY = VALUE` setting line inside [PROVIDER] (used for vertex
# `project`/`region`/`account`), preserving the section's models and other
# settings. Replaces an existing KEY line wherever it sits; otherwise inserts it
# right after the header. Appends a new section if PROVIDER isn't present.
conf_set_section_setting() {
  local target="$1" key="$2" value="$3"
  local newline="${key} = ${value}"
  local line in_target=0 found=0 k
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^\[(.+)\]$ ]]; then
      in_target=0
      printf '%s\n' "$line"
      if [[ "${BASH_REMATCH[1]}" == "$target" ]]; then
        in_target=1
        found=1
        printf '%s\n' "$newline"
      fi
      continue
    fi
    if [[ $in_target -eq 1 && "$line" == *=* ]]; then
      k="${line%%=*}"
      k="${k//[[:space:]]/}"
      [[ "$k" == "$key" ]] && continue # drop the old KEY line
    fi
    printf '%s\n' "$line"
  done
  if [[ $found -eq 0 ]]; then
    printf '\n[%s]\n%s\n' "$target" "$newline"
  fi
}

# Parse the user options file and emit one "provider:model" line per enabled
# combo. Empty sections drop that provider entirely. Unknown provider section
# names are silently ignored. Custom model IDs (not in the shipped catalog)
# are passed through as-is.
#
# A `projects =` list under a shared [vertex] section expands each base vertex
# section (`[vertex-gemini]` / `[vertex-anthropic]`) into one profile per
# project — `vertex-<x>@<project>:<model>` — so the cross product of providers
# and projects need not be spelled out. Explicit `[vertex-<x>@<profile>]`
# sections still emit directly and coexist (duplicates are dropped).
parse_user_options() {
  local path
  path=$(user_options_path)
  [[ -r "$path" ]] || return 0

  # Pull the shared [vertex] projects list (comma- or space-separated).
  local -a vertex_projects=()
  local proj_raw p
  proj_raw=$(vertex_config_value "vertex" projects)
  if [[ -n "$proj_raw" ]]; then
    while IFS= read -r p || [[ -n "$p" ]]; do
      [[ -n "$p" ]] && vertex_projects+=("$p")
    done < <(printf '%s' "$proj_raw" | tr ', ' '\n')
  fi

  local line trimmed section="" value emitted=$'\n'
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Strip inline # comment then surrounding whitespace.
    trimmed="${line%%#*}"
    trimmed="${trimmed#"${trimmed%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [[ -n "$trimmed" ]] || continue

    if [[ "$trimmed" =~ ^\[([^][]+)\]$ ]]; then
      local candidate="${BASH_REMATCH[1]}"
      if provider_is_valid "$candidate" && [[ "$candidate" != "last" ]]; then
        section="$candidate"
      else
        # Unrecognised headers (incl. the shared [vertex] section, which is not
        # a valid provider on its own) clear `section`, so any model IDs listed
        # under them are silently skipped — only their key=value lines (e.g.
        # [vertex] projects=) are consumed, via vertex_config_value. A model put
        # under [vertex] by mistake belongs under [vertex-gemini]/[vertex-anthropic].
        section=""
      fi
      continue
    fi

    [[ -n "$section" ]] || continue
    # key=value lines configure the section (e.g. vertex account/project) and
    # are not model IDs — model IDs never contain '='. Skip them here.
    [[ "$trimmed" == *=* ]] && continue

    # Expand base vertex sections across the shared projects list; everything
    # else (explicit @profiles, non-vertex providers) emits verbatim.
    if [[ ${#vertex_projects[@]} -gt 0 \
          && ( "$section" == "vertex-gemini" || "$section" == "vertex-anthropic" ) ]]; then
      for p in "${vertex_projects[@]}"; do
        value="${section}@${p}:${trimmed}"
        case "$emitted" in *$'\n'"$value"$'\n'*) continue ;; esac
        printf '%s\n' "$value"
        emitted+="$value"$'\n'
      done
    else
      value="${section}:${trimmed}"
      case "$emitted" in *$'\n'"$value"$'\n'*) continue ;; esac
      printf '%s\n' "$value"
      emitted+="$value"$'\n'
    fi
  done <"$path"
}

# vertex_config_value PROVIDER KEY
# Emit the value of a key=value line under the given provider's section in the
# user options file. Recognised keys: project, projects, region, account,
# credentials. (`projects` is the comma/space-separated list read from the
# shared [vertex] section to expand profiles; see parse_user_options.)
# A leading '~/' in the value is expanded to $HOME. Prints nothing (and returns
# 0) when the file, section, or key is absent.
vertex_config_value() {
  local want_provider="$1" want_key="$2"
  local path
  path=$(user_options_path)
  [[ -r "$path" ]] || return 0

  local line trimmed section="" key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    trimmed="${line%%#*}"
    trimmed="${trimmed#"${trimmed%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [[ -n "$trimmed" ]] || continue

    if [[ "$trimmed" =~ ^\[([^][]+)\]$ ]]; then
      section="${BASH_REMATCH[1]}"
      continue
    fi

    [[ "$section" == "$want_provider" ]] || continue
    [[ "$trimmed" == *=* ]] || continue
    key="${trimmed%%=*}"
    val="${trimmed#*=}"
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    if [[ "$key" == "$want_key" ]]; then
      # Match a literal leading '~/' and expand it ourselves; the tilde is data
      # here, not a path to be shell-expanded.
      # shellcheck disable=SC2088
      [[ "$val" == "~/"* ]] && val="${HOME}/${val#\~/}"
      printf '%s\n' "$val"
      return 0
    fi
  done <"$path"
  return 0
}

# vertex_resolve TOKEN KEY
# Resolve a vertex setting for a (possibly profile-qualified) provider TOKEN,
# layering most-specific first: the explicit [base@profile] section, then the
# base [base] section, then the shared [vertex] section. For KEY=project with
# no value found, the profile name is used as the project id (so the profile
# name is the project unless overridden). Prints nothing when unresolved.
vertex_resolve() {
  local token="$1" key="$2"
  local base="${token%%@*}" profile="" val
  case "$token" in *@*) profile="${token#*@}" ;; esac

  val=$(vertex_config_value "$token" "$key")
  [[ -n "$val" ]] && { printf '%s\n' "$val"; return 0; }

  if [[ -n "$profile" ]]; then
    val=$(vertex_config_value "$base" "$key")
    [[ -n "$val" ]] && { printf '%s\n' "$val"; return 0; }
  fi

  val=$(vertex_config_value "vertex" "$key")
  [[ -n "$val" ]] && { printf '%s\n' "$val"; return 0; }

  # The profile name doubles as the project id when none is configured.
  if [[ "$key" == "project" && -n "$profile" ]]; then
    printf '%s\n' "$profile"
    return 0
  fi
  return 0
}

# list_options TOOL
# Emits one "value|label" line per selectable combo for TOOL (commit|pr).
# Values are either "last" (commit only, when saved message exists) or
# "provider:model". History-ordered entries come first, then remaining
# combos in provider-major / model-minor default order. If a user options
# file exists at $XDG_CONFIG_HOME/git-ai/options.conf it fully replaces the
# default provider/model catalog for this listing.
list_options() {
  local tool_name="${1:-commit}"
  local providers=(vertex-gemini vertex-anthropic gemini-api claude-code anthropic-api codex openai-api)

  # Build candidate table as a newline-delimited "value<TAB>label" string
  # (bash 3.2 on macOS has no associative arrays).
  local table=""

  if [[ "$tool_name" == "commit" ]]; then
    local git_dir
    if git_dir=$(git rev-parse --git-dir 2>/dev/null) && \
       [[ -r "${git_dir}/commit-last-message" ]]; then
      table+=$'last\treuse saved message\n'
    fi
  fi

  local user_entries
  user_entries=$(parse_user_options)

  # A present options.conf is authoritative: only its pinned provider:model
  # entries are offered (an empty [provider] section hides that provider, per the
  # file's own documentation). Live discovery is the fallback ONLY when no
  # options.conf exists at all — otherwise enabling a provider with no pinned
  # model would flood the picker with every discovered model.
  local provider model display short
  if [[ -e "$(user_options_path)" ]]; then
    while IFS=':' read -r provider model; do
      [[ -n "$provider" && -n "$model" ]] || continue
      display=$(provider_display_name "$provider")
      short="${model%-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]}"
      table+="${provider}:${model}"$'\t'"${short} · ${display}"$'\n'
    done <<< "$user_entries"
  else
    for provider in "${providers[@]}"; do
      display=$(provider_display_name "$provider")
      while IFS= read -r model; do
        [[ -n "$model" ]] || continue
        short="${model%-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]}"
        table+="${provider}:${model}"$'\t'"${short} · ${display}"$'\n'
      done < <(discover_models "$provider")
    done
  fi

  # Emit history entries first (only those present in the candidate table),
  # then remaining candidates in their default order. Track emitted values
  # in a newline-delimited string so we can check membership without
  # associative arrays.
  local emitted=$'\n'
  local entry label

  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    case "$emitted" in
      *$'\n'"$entry"$'\n'*) continue ;;
    esac
    # Pure-bash table lookup — an awk pipeline here costs two forks per
    # history entry on every picker open.
    label=""
    local cand_value cand_label
    while IFS=$'\t' read -r cand_value cand_label; do
      [[ "$cand_value" == "$entry" ]] && { label="$cand_label"; break; }
    done <<< "$table"
    [[ -n "$label" ]] || continue
    printf '%s|%s\n' "$entry" "$label"
    emitted+="$entry"$'\n'
  done < <(get_choice_history "$tool_name")

  while IFS=$'\t' read -r entry label; do
    [[ -n "$entry" ]] || continue
    case "$emitted" in
      *$'\n'"$entry"$'\n'*) continue ;;
    esac
    printf '%s|%s\n' "$entry" "$label"
    emitted+="$entry"$'\n'
  done <<< "$table"
}

# pick_via_fzf TOOL
# Launch fzf over list_options output, echo the selected value (text before
# the '|' delimiter). Returns non-zero if fzf is missing, GIT_AI_NO_FZF is
# set, or the user cancels. Caller is responsible for the tty check — this
# function is invoked inside $(...) so its own stdout is never a tty.
# pick_or_recall_provider TOOL [IS_TTY]
# On an interactive stdout, offers the fzf picker; otherwise (or on cancel)
# falls back to the tool's saved provider. Prints "provider" or
# "provider:model". Non-zero if neither a pick nor a saved provider exists.
# IS_TTY must be evaluated by the caller (this runs in $(...) with fd 1 piped).
pick_or_recall_provider() {
  local tool_name="$1"
  local is_tty="${2:-false}"
  local picked
  if [[ "$is_tty" == "true" ]] && picked=$(pick_via_fzf "$tool_name"); then
    printf '%s\n' "$picked"
    return 0
  fi
  picked=$(get_last_provider "$tool_name")
  [[ -n "$picked" ]] || return 1
  printf '%s\n' "$picked"
}

pick_via_fzf() {
  local tool_name="${1:-commit}"
  command -v fzf >/dev/null 2>&1 || return 127
  [[ -z "${GIT_AI_NO_FZF:-}" ]] || return 1

  local choice
  choice=$(list_options "$tool_name" | fzf \
    --delimiter='|' --with-nth=2 --no-sort --tiebreak=index \
    --prompt="git-ai ${tool_name}> " --height=40% --reverse) || return 1
  [[ -n "$choice" ]] || return 1
  printf '%s\n' "${choice%%|*}"
}

# With no curated catalog there's no hardcoded default. Prefer the tool's last
# saved pick for this provider; otherwise fall back to the first model discovery
# returns (which is the API's newest-first / our sort order). May print nothing
# when offline with a cold cache and no saved pick — resolve_model surfaces that.
default_model_for_provider() {
  local tool_name="$1"
  local provider="$2"
  provider_family "$provider" >/dev/null || return 1

  local last
  last=$(get_last_model "$tool_name" "$provider" "")
  if [[ -n "$last" ]]; then
    printf '%s\n' "$last"
    return 0
  fi
  discover_models "$provider" 2>/dev/null | head -n1
}

# Model IDs are no longer validated against a fixed list: an explicit model is
# passed through verbatim (the provider API rejects a genuinely bad id at call
# time). With no model, fall back to the per-provider default.
resolve_model() {
  local tool_name="$1"
  local provider="$2"
  local model="${3:-}"

  if [[ -n "$model" ]]; then
    printf '%s\n' "$model"
    return
  fi

  local default
  default=$(default_model_for_provider "$tool_name" "$provider")
  if [[ -z "$default" ]]; then
    die "could not determine a model for '$provider' — pass one explicitly (e.g. 'git-ai $tool_name $provider <model>') or run 'git-ai setup'."
  fi
  printf '%s\n' "$default"
}

_run_gemini_cli() {
  local model="$1"
  local prompt="$2"
  local input="$3"
  local gemini_bin err_file out status err
  gemini_bin=$(resolve_gemini_bin) || die "Gemini CLI not found. Set GEMINI_BIN or add gemini to PATH."
  err_file=$(mktemp "${TMPDIR:-/tmp}/git-ai-gemini.XXXXXX") ||
    die "failed to create temporary error file"
  trap 'rm -f "$err_file"' EXIT
  out=$(printf '%s\n' "$input" | "$gemini_bin" -p "$prompt" -m "$model" -e "" 2>"$err_file")
  status=$?
  if [[ $status -ne 0 ]]; then
    err=$(<"$err_file")
    rm -f "$err_file"
    [[ -n "$err" ]] && die "Gemini generation failed: $err"
    die "Gemini generation failed"
  fi
  rm -f "$err_file"
  printf '%s\n' "$out"
}

_vertex_endpoint() {
  local project="$1" region="$2" publisher="$3" model="$4" method="$5"
  local host
  [[ "$region" == "global" ]] && host="aiplatform.googleapis.com" \
                               || host="${region}-aiplatform.googleapis.com"
  printf 'https://%s/v1/projects/%s/locations/%s/publishers/%s/models/%s:%s\n' \
    "$host" "$project" "$region" "$publisher" "$model" "$method"
}

_run_vertex_anthropic_api() {
  local model="$1" prompt="$2" input="$3" project="$4" region="$5" account="${6:-}"
  local token body url curl_cfg response
  token=$(_vertex_access_token "$account") ||
    die "Vertex auth: gcloud print-access-token failed."
  body=$(GIT_AI_PROMPT="$prompt" GIT_AI_INPUT="$input" python3 -c '
import json, os
print(json.dumps({
  "anthropic_version": "vertex-2023-10-16",
  "max_tokens": 8192,
  "system": os.environ["GIT_AI_PROMPT"],
  "messages": [{"role": "user", "content": os.environ["GIT_AI_INPUT"]}]
}))') || die "Failed to build Vertex Anthropic request"
  url=$(_vertex_endpoint "$project" "$region" "anthropic" "$model" "rawPredict")
  curl_cfg=$(mktemp "${TMPDIR:-/tmp}/git-ai-curl.XXXXXX") || die "failed to create curl config file"
  trap 'rm -f "$curl_cfg"' EXIT
  printf 'header = "Authorization: Bearer %s"\n' "$token" > "$curl_cfg"
  response=$(curl -sf -K "$curl_cfg" -H "content-type: application/json" -d "$body" "$url")
  local curl_status=$?
  rm -f "$curl_cfg"
  [[ $curl_status -eq 0 ]] || die "Vertex Anthropic API request failed"
  python3 -c '
import json, sys
data = json.loads(sys.stdin.read())
print(data["content"][0]["text"])
' <<<"$response" || die "Failed to parse Vertex Anthropic response"
}

_run_vertex_gemini_api() {
  local model="$1" prompt="$2" input="$3" project="$4" region="$5" account="${6:-}"
  local token body url curl_cfg response
  token=$(_vertex_access_token "$account") ||
    die "Vertex auth: gcloud print-access-token failed."
  body=$(GIT_AI_PROMPT="$prompt" GIT_AI_INPUT="$input" python3 -c '
import json, os
print(json.dumps({
  "systemInstruction": {"parts": [{"text": os.environ["GIT_AI_PROMPT"]}]},
  "contents": [{"role": "user", "parts": [{"text": os.environ["GIT_AI_INPUT"]}]}]
}))') || die "Failed to build Vertex Gemini request"
  url=$(_vertex_endpoint "$project" "$region" "google" "$model" "generateContent")
  curl_cfg=$(mktemp "${TMPDIR:-/tmp}/git-ai-curl.XXXXXX") || die "failed to create curl config file"
  trap 'rm -f "$curl_cfg"' EXIT
  printf 'header = "Authorization: Bearer %s"\n' "$token" > "$curl_cfg"
  response=$(curl -sf -K "$curl_cfg" -H "content-type: application/json" -d "$body" "$url")
  local curl_status=$?
  rm -f "$curl_cfg"
  [[ $curl_status -eq 0 ]] || die "Vertex Gemini API request failed"
  python3 -c '
import json, sys
data = json.loads(sys.stdin.read())
print(data["candidates"][0]["content"]["parts"][0]["text"])
' <<<"$response" || die "Failed to parse Vertex Gemini response"
}

_run_anthropic_api() {
  local model="$1"
  local prompt="$2"
  local input="$3"
  local body response curl_cfg
  body=$(GIT_AI_MODEL="$model" GIT_AI_PROMPT="$prompt" GIT_AI_INPUT="$input" \
    python3 -c '
import json, os
print(json.dumps({
  "model": os.environ["GIT_AI_MODEL"],
  "max_tokens": 8192,
  "system": os.environ["GIT_AI_PROMPT"],
  "messages": [{"role": "user", "content": os.environ["GIT_AI_INPUT"]}]
}))
') || die "Failed to build Anthropic API request"
  curl_cfg=$(mktemp "${TMPDIR:-/tmp}/git-ai-curl.XXXXXX") || die "failed to create curl config file"
  trap 'rm -f "$curl_cfg"' EXIT
  printf 'header = "x-api-key: %s"\n' "$ANTHROPIC_API_KEY" > "$curl_cfg"
  response=$(curl -sf \
    -K "$curl_cfg" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d "$body" \
    "https://api.anthropic.com/v1/messages")
  local curl_status=$?
  rm -f "$curl_cfg"
  [[ $curl_status -eq 0 ]] || die "Anthropic API request failed"
  python3 -c '
import json, sys
data = json.loads(sys.stdin.read())
print(data["content"][0]["text"])
' <<<"$response" || die "Failed to parse Anthropic API response"
}

_run_openai_api() {
  local model="$1"
  local prompt="$2"
  local input="$3"
  local body response curl_cfg
  body=$(GIT_AI_MODEL="$model" GIT_AI_PROMPT="$prompt" GIT_AI_INPUT="$input" \
    python3 -c '
import json, os
print(json.dumps({
  "model": os.environ["GIT_AI_MODEL"],
  "messages": [
    {"role": "system", "content": os.environ["GIT_AI_PROMPT"]},
    {"role": "user",   "content": os.environ["GIT_AI_INPUT"]}
  ]
}))
') || die "Failed to build OpenAI API request"
  curl_cfg=$(mktemp "${TMPDIR:-/tmp}/git-ai-curl.XXXXXX") || die "failed to create curl config file"
  trap 'rm -f "$curl_cfg"' EXIT
  printf 'header = "Authorization: Bearer %s"\n' "$OPENAI_API_KEY" > "$curl_cfg"
  response=$(curl -sf \
    -K "$curl_cfg" \
    -H "content-type: application/json" \
    -d "$body" \
    "https://api.openai.com/v1/chat/completions")
  local curl_status=$?
  rm -f "$curl_cfg"
  [[ $curl_status -eq 0 ]] || die "OpenAI API request failed"
  python3 -c '
import json, sys
data = json.loads(sys.stdin.read())
print(data["choices"][0]["message"]["content"])
' <<<"$response" || die "Failed to parse OpenAI API response"
}

# run_provider TOOL_NAME PROVIDER PROMPT INPUT [MODEL]
# Runs the given LLM provider with the prompt and input, pipes through strip_fences.
run_provider() {
  local tool_name="$1"
  local provider="$2"
  local prompt="$3"
  local input="$4"
  local selected_model="${5:-}"
  local output
  local model provider_base_name
  # A provider may be profile-qualified (base@profile); dispatch on the base,
  # but look up account/project config under the full token (= section name).
  provider_base_name="${provider%%@*}"
  model=$(resolve_model "$tool_name" "$provider" "$selected_model")

  case $provider_base_name in
    claude-code)
      command -v claude >/dev/null 2>&1 ||
        die "Claude Code auth requires the Claude Code CLI. See: https://claude.ai/code"
      claude -p "$prompt" --max-turns 1 --model "$model" <<<"$input" | strip_fences ||
        die "Claude generation failed"
      ;;
    anthropic-api)
      local anthropic_key
      anthropic_key=$(resolve_api_key anthropic-api-key ANTHROPIC_API_KEY) ||
        die "Anthropic API auth not found. Set ANTHROPIC_API_KEY or store 'anthropic-api-key' in your keychain."
      export ANTHROPIC_API_KEY="$anthropic_key"
      _run_anthropic_api "$model" "$prompt" "$input" | strip_fences ||
        die "Anthropic API generation failed"
      ;;
    vertex-gemini|vertex-anthropic)
      load_google_env
      # Per-provider account config (options.conf) overrides env. account=
      # selects a gcloud user credential; credentials= points ADC at a
      # service-account JSON. Both are optional — absent both, plain ADC is used.
      local vertex_project vertex_region vertex_account vertex_creds
      vertex_account=$(vertex_resolve "$provider" account)
      vertex_creds=$(vertex_resolve "$provider" credentials)
      vertex_project=$(vertex_resolve "$provider" project)
      vertex_project="${vertex_project:-${GOOGLE_VERTEX_PROJECT:-${GOOGLE_CLOUD_PROJECT:-}}}"
      vertex_region=$(vertex_resolve "$provider" region)
      vertex_region="${vertex_region:-${VERTEX_LOCATION:-${GOOGLE_VERTEX_LOCATION:-${GOOGLE_CLOUD_LOCATION:-us-central1}}}}"

      if [[ -n "$vertex_creds" ]]; then
        export GOOGLE_APPLICATION_CREDENTIALS="$vertex_creds"
      fi

      _vertex_has_auth "$vertex_account" ||
        die "Vertex auth not found. Configure gcloud ADC, set account=/credentials= under [$provider] in options.conf, or GOOGLE_APPLICATION_CREDENTIALS."
      [[ -n "$vertex_project" ]] ||
        die "Vertex auth requires a project (set project= under [$provider] in options.conf, or GOOGLE_CLOUD_PROJECT/GOOGLE_VERTEX_PROJECT)."

      if [[ -n "$vertex_account" ]]; then
        echo "git-ai: Vertex account ${vertex_account} · project ${vertex_project} (${vertex_region})" >&2
      elif [[ -n "$vertex_creds" ]]; then
        echo "git-ai: Vertex credentials ${vertex_creds} · project ${vertex_project} (${vertex_region})" >&2
      else
        echo "git-ai: Vertex ADC · project ${vertex_project} (${vertex_region})" >&2
      fi

      if [[ "$provider_base_name" == "vertex-anthropic" ]]; then
        _run_vertex_anthropic_api "$model" "$prompt" "$input" "$vertex_project" "$vertex_region" "$vertex_account" | strip_fences
      else
        _run_vertex_gemini_api "$model" "$prompt" "$input" "$vertex_project" "$vertex_region" "$vertex_account" | strip_fences
      fi
      ;;
    gemini-api)
      load_google_env
      local gemini_api_key
      gemini_api_key=$(resolve_gemini_api_key) ||
        die "Gemini API auth not found. Set GEMINI_API_KEY or store 'gemini-api-key' in your keychain."
      export GEMINI_API_KEY="$gemini_api_key"
      _run_gemini_cli "$model" "$prompt" "$input" | strip_fences
      ;;
    codex)
      command -v codex >/dev/null 2>&1 ||
        die "Codex auth requires the Codex CLI. See: https://github.com/openai/codex"
      local codex_output_file
      local codex_err_file
      codex_output_file=$(mktemp "${TMPDIR:-/tmp}/git-ai-codex.XXXXXX") ||
        die "failed to create temporary output file"
      codex_err_file=$(mktemp "${TMPDIR:-/tmp}/git-ai-codex-err.XXXXXX") ||
        die "failed to create temporary error file"
      trap 'rm -f "$codex_output_file" "$codex_err_file"' EXIT
      printf '%s\n\n%s' "$prompt" "$input" |
        codex exec --model "$model" --output-last-message "$codex_output_file" - \
        >/dev/null 2>"$codex_err_file" || {
        local codex_error
        codex_error=$(<"$codex_err_file")
        rm -f "$codex_output_file" "$codex_err_file"
        [[ -n "$codex_error" ]] && die "Codex generation failed: $codex_error"
        die "Codex generation failed"
      }
      rm -f "$codex_err_file"
      output=$(<"$codex_output_file")
      rm -f "$codex_output_file"
      [[ -n "$output" ]] || die "Codex generation failed: empty response"
      printf '\n%s\n' "$output" | strip_fences
      ;;
    openai-api)
      local openai_key
      openai_key=$(resolve_api_key openai-api-key OPENAI_API_KEY) ||
        die "OpenAI API auth not found. Set OPENAI_API_KEY or store 'openai-api-key' in your keychain."
      export OPENAI_API_KEY="$openai_key"
      _run_openai_api "$model" "$prompt" "$input" | strip_fences ||
        die "OpenAI API generation failed"
      ;;
    *)
      die "unknown provider: $provider"
      ;;
  esac
  save_last_provider "$tool_name" "$provider"
  [[ -n "$selected_model" ]] && save_last_model "$tool_name" "$provider" "$selected_model"
  push_choice_history "$tool_name" "${provider}:${model}"
}
