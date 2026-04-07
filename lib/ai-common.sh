#!/bin/bash
# ai-common.sh - Shared functions for git-ai tools

die() {
  echo "${0##*/}: $*" >&2
  exit 1
}

strip_fences() {
  perl -0pe '
    s/^\s*```.*\n//mg;
    s/^\s*`+\s*$\n?//mg;
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
  get_last_choice "${1}-last-provider" "${2:-claude}" "claude|gemini|codex"
}

save_last_provider() {
  save_last_choice "${1}-last-provider" "$2"
}

get_last_tier() {
  local tool_name="$1"
  local provider="$2"
  local fallback="$3"
  get_last_choice "${tool_name}-${provider}-last-tier" "$fallback" \
    "haiku|sonnet|opus|flash-lite|pro|mini|standard"
}

save_last_tier() {
  save_last_choice "${1}-${2}-last-tier" "$3"
}

load_gemini_env() {
  local private_env_file="${HOME}/.zsh-private"

  if [[ -r "$private_env_file" ]]; then
    # shellcheck disable=SC1090
    source "$private_env_file"
  fi

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
}

resolve_gemini_bin() {
  local candidate
  local candidates=(
    "${GEMINI_BIN:-}"
    "$HOME/.nvm/versions/node/v25.1.0/bin/gemini"
    "$HOME/.nvm/versions/node/v24.11.0/bin/gemini"
    "$HOME/.nvm/versions/node/v20.19.5/bin/gemini"
    "$HOME/.nvm/versions/node/v20.10.0/bin/gemini"
    "$HOME/.local/bin/gemini"
    "/opt/homebrew/bin/gemini"
    "/usr/local/bin/gemini"
  )

  for candidate in "${candidates[@]}"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  if command -v gemini >/dev/null 2>&1; then
    command -v gemini
    return 0
  fi

  return 1
}

resolve_gemini_api_key() {
  local keychain_account
  local key

  if [[ -n "${GEMINI_API_KEY:-}" ]]; then
    printf '%s\n' "$GEMINI_API_KEY"
    return 0
  fi

  keychain_account="${USER:-${LOGNAME:-$(id -un 2>/dev/null)}}"

  if [[ -n "$keychain_account" ]]; then
    key=$(security find-generic-password -a "$keychain_account" -s "gemini-api-key" -w 2>/dev/null) && [[ -n "$key" ]] && {
      printf '%s\n' "$key"
      return 0
    }
  fi

  key=$(security find-generic-password -s "gemini-api-key" -w 2>/dev/null) && [[ -n "$key" ]] && {
    printf '%s\n' "$key"
    return 0
  }

  return 1
}

provider_display_name() {
  case $1 in
    claude) echo "Claude" ;;
    gemini) echo "Gemini" ;;
    codex)  echo "OpenAI (Codex)" ;;
  esac
}

tier_display_name() {
  case $1 in
    haiku)      echo "Haiku" ;;
    sonnet)     echo "Sonnet" ;;
    opus)       echo "Opus" ;;
    flash-lite) echo "Flash Lite" ;;
    pro)        echo "Pro" ;;
    mini)       echo "Mini" ;;
    standard)   echo "Standard" ;;
  esac
}

# order_by_recent LAST ITEM...
# Prints items with LAST first, then remaining in original order.
order_by_recent() {
  local last="$1"
  shift
  printf '%s\n' "$last"
  for item in "$@"; do
    [[ "$item" != "$last" ]] && printf '%s\n' "$item"
  done
}

list_providers() {
  local tool_name="${1:-}"
  local all=(claude gemini codex)

  if [[ -n "$tool_name" ]]; then
    local last ordered=()
    last=$(get_last_provider "$tool_name")
    while IFS= read -r p; do ordered+=("$p"); done < <(order_by_recent "$last" "${all[@]}")
    all=("${ordered[@]}")
  fi

  for p in "${all[@]}"; do
    printf '%s|%s\n' "$p" "$(provider_display_name "$p")"
  done
}

list_tiers() {
  local provider="${1:-}"
  local tool_name="${2:-}"
  local all=()

  case "$provider" in
    claude) all=(haiku sonnet opus) ;;
    gemini) all=(flash-lite pro) ;;
    codex)  all=(mini standard) ;;
    *) return ;;
  esac

  if [[ -n "$tool_name" ]]; then
    local last ordered=()
    last=$(get_last_tier "$tool_name" "$provider" "${all[0]}")
    while IFS= read -r t; do ordered+=("$t"); done < <(order_by_recent "$last" "${all[@]}")
    all=("${ordered[@]}")
  fi

  for t in "${all[@]}"; do
    printf '%s|%s\n' "$t" "$(tier_display_name "$t")"
  done
}

resolve_model() {
  local tool_name="$1"
  local provider="$2"
  local tier="${3:-}"

  if [[ -n "$tier" ]]; then
    case "${provider}:${tier}" in
      claude:haiku)      printf '%s\n' "claude-haiku-4-5-20251001" ;;
      claude:sonnet)     printf '%s\n' "claude-sonnet-4-6" ;;
      claude:opus)       printf '%s\n' "claude-opus-4-6" ;;
      gemini:flash-lite) printf '%s\n' "gemini-3.1-flash-lite-preview" ;;
      gemini:pro)        printf '%s\n' "gemini-3.1-pro-preview" ;;
      codex:mini)        printf '%s\n' "gpt-5.4-mini" ;;
      codex:standard)    printf '%s\n' "gpt-5.4" ;;
      *) die "unknown model tier '$tier' for provider '$provider'" ;;
    esac
    return
  fi

  case "${tool_name}:${provider}" in
    ai-pr-title:claude) printf '%s\n' "claude-opus-4-6" ;;
    ai-pr-title:gemini) printf '%s\n' "gemini-3.1-pro-preview" ;;
    ai-pr-title:codex)  printf '%s\n' "gpt-5.4" ;;
    *:claude) printf '%s\n' "claude-haiku-4-5-20251001" ;;
    *:gemini) printf '%s\n' "gemini-3.1-flash-lite-preview" ;;
    *:codex)  printf '%s\n' "gpt-5.4-mini" ;;
  esac
}

# run_provider TOOL_NAME PROVIDER PROMPT INPUT [MODEL_TIER]
# Runs the given LLM provider with the prompt and input, pipes through strip_fences.
run_provider() {
  local tool_name="$1"
  local provider="$2"
  local prompt="$3"
  local input="$4"
  local model_tier="${5:-}"
  local output
  local model
  model=$(resolve_model "$tool_name" "$provider" "$model_tier")

  case $provider in
    claude)
      claude -p "$prompt" --max-turns 1 --model "$model" <<<"$input" | strip_fences ||
        die "Claude generation failed"
      ;;
    gemini)
      load_gemini_env
      local gemini_err_file
      gemini_err_file=$(mktemp "${TMPDIR:-/tmp}/git-ai-gemini.XXXXXX") ||
        die "failed to create temporary error file"
      local gemini_bin
      gemini_bin=$(resolve_gemini_bin) || die "Gemini CLI not found. Set GEMINI_BIN or add gemini to PATH."
      GEMINI_API_KEY=$(resolve_gemini_api_key) || die "Gemini API key not found. Set GEMINI_API_KEY or store a keychain item named gemini-api-key."
      export GEMINI_API_KEY
      local gemini_output
      gemini_output=$(
        printf '%s\n' "$input" | "$gemini_bin" -p "$prompt" -m "$model" -e "" 2>"$gemini_err_file"
      )
      local gemini_status=$?

      if [[ $gemini_status -ne 0 ]]; then
        local gemini_error
        gemini_error=$(<"$gemini_err_file")
        rm -f "$gemini_err_file"

        if [[ -n "$gemini_error" ]]; then
          die "Gemini generation failed: $gemini_error"
        fi

        die "Gemini generation failed"
      fi

      rm -f "$gemini_err_file"
      printf '%s\n' "$gemini_output" | strip_fences
      ;;
    codex)
      local codex_output_file
      local codex_err_file
      codex_output_file=$(mktemp "${TMPDIR:-/tmp}/git-ai-codex.XXXXXX") ||
        die "failed to create temporary output file"
      codex_err_file=$(mktemp "${TMPDIR:-/tmp}/git-ai-codex-err.XXXXXX") ||
        die "failed to create temporary error file"
      codex exec --model "$model" --output-last-message "$codex_output_file" "$prompt

$input" >/dev/null 2>"$codex_err_file" || {
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
    *)
      die "unknown provider: $provider"
      ;;
  esac
  save_last_provider "$tool_name" "$provider"
  [[ -n "$model_tier" ]] && save_last_tier "$tool_name" "$provider" "$model_tier"
}
