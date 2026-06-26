#!/bin/bash
# auth.sh - provider auth, key resolution, provider metadata (sourced via lib/ai-common.sh).

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
    # macOS `security` has no stdin/file input for the password, so the key is
    # passed via `-w` argv and is briefly visible in `ps` while this runs — an
    # unavoidable limitation of this backend (the secret-tool/pass paths below
    # pipe the key via stdin and avoid the exposure).
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
  # Single-quote the key so it never re-interprets, escaping any embedded '
  # for the target shell: fish escapes it as \', POSIX shells close-escape-reopen
  # ('\''). q holds a literal single quote so the replacements stay readable.
  local q="'"
  case "$sh" in
    fish) printf "set -gx %s '%s'\n" "$envvar" "${key//$q/\\$q}" ;;
    *)    printf "export %s='%s'\n" "$envvar" "${key//$q/$q\\$q$q}" ;;
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
      # run_provider's gemini-api path shells out to the Gemini CLI, so a key
      # alone isn't enough — the binary must resolve too.
      if ! resolve_gemini_bin >/dev/null 2>&1; then
        printf 'Gemini CLI not found (set GEMINI_BIN or add gemini to PATH)\n' >&2
        return 1
      fi
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
      # A shared projects list counts too — each entry becomes a runnable
      # @project profile, so the provider is configured even without project=.
      project="${project:-$(vertex_config_value vertex projects)}"
      [[ -n "$project" ]] && return 0
      printf 'Vertex project not set (project=, projects=, or GOOGLE_CLOUD_PROJECT)\n' >&2 ;;
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

# The gcloud-active project ("gcloud config get-value project"), empty when
# unset or when gcloud is absent.
_gcloud_active_project() {
  command -v gcloud >/dev/null 2>&1 || return 0
  local p
  p=$(gcloud config get-value project 2>/dev/null)
  [[ "$p" == "(unset)" ]] && p=""
  printf '%s' "$p"
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

# Curated recommended-model defaults live in a dedicated DATA file so model
# bumps read as data changes, not code changes (commits touching only that file
# are routine "chore: bump recommended X model" updates). It is a packaged asset
# resolved through GIT_AI_PKG_DIR so the pip wheel's flattened layout finds it.
# Pre-set env wins so tests can pin a fixture instead of the live data file.
GIT_AI_RECOMMENDED_MODELS_FILE="${GIT_AI_RECOMMENDED_MODELS_FILE:-${GIT_AI_PKG_DIR}/recommended-models.conf}"

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
    key=$(_trim "${line%%=*}")
    [[ "$key" == "$family" ]] || continue
    val=$(_trim "${line#*=}")
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
