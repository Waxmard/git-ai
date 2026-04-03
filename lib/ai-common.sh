#!/bin/bash
# ai-common.sh - Shared functions for git-ai tools

die() {
  echo "${0##*/}: $*" >&2
  exit 1
}

strip_fences() {
  perl -0pe '
    s/^\s*```.*\n//mg;
    s/^`+//mg;
    s/`+$//mg;
    s/\A(?:[ \t]*\n)+//;
    s/(?:\n[ \t]*)+\z/\n/s;
  '
}

get_last_provider() {
  local tool_name="$1"
  local fallback="${2:-claude}"
  local git_dir
  git_dir=$(git rev-parse --git-dir 2>/dev/null) || { printf '%s\n' "$fallback"; return 0; }
  local state_file="${git_dir}/${tool_name}-last-provider"
  if [[ -r "$state_file" ]]; then
    local stored
    stored=$(<"$state_file")
    stored="${stored%"${stored##*[![:space:]]}"}"
    case $stored in
      claude|gemini|codex) printf '%s\n' "$stored"; return 0 ;;
    esac
  fi
  printf '%s\n' "$fallback"
}

save_last_provider() {
  local tool_name="$1"
  local provider="$2"
  local git_dir
  git_dir=$(git rev-parse --git-dir 2>/dev/null) || return 0
  printf '%s\n' "$provider" >"${git_dir}/${tool_name}-last-provider" 2>/dev/null || true
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

list_tiers() {
  case "${1:-}" in
    claude)
      printf '%s|%s\n' "haiku" "Haiku"
      printf '%s|%s\n' "sonnet" "Sonnet"
      printf '%s|%s\n' "opus" "Opus"
      ;;
    gemini)
      printf '%s|%s\n' "flash-lite" "Flash Lite"
      printf '%s|%s\n' "flash" "Flash"
      printf '%s|%s\n' "pro" "Pro"
      ;;
    codex)
      printf '%s|%s\n' "mini" "Mini"
      printf '%s|%s\n' "standard" "Standard"
      ;;
  esac
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
      gemini:flash)      printf '%s\n' "gemini-3.1-flash-preview" ;;
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
}
