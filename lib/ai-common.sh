#!/bin/bash
# ai-common.sh - Shared functions for git-ai tools

die() {
  echo "${0##*/}: $*" >&2
  exit 1
}

strip_fences() {
  sed -E '/^```/d' | sed -E 's/^`+//;s/`+$//' | sed -E '/./,$!d' | sed -E ':a;/^[[:space:]]*$/{ $d;N;ba; }'
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

# run_provider PROVIDER PROMPT INPUT
# Runs the given LLM provider with the prompt and input, pipes through strip_fences.
run_provider() {
  local provider="$1"
  local prompt="$2"
  local input="$3"

  case $provider in
    claude)
      claude -p "$prompt" --max-turns 1 --model claude-haiku-4-5-20251001 <<<"$input" | strip_fences ||
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
        printf '%s\n' "$input" | "$gemini_bin" -p "$prompt" -m gemini-3.1-flash-lite-preview -e "" 2>"$gemini_err_file"
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
      codex exec --model gpt-5.4-mini "$prompt

$input" | strip_fences || die "Codex generation failed"
      ;;
    *)
      die "unknown provider: $provider"
      ;;
  esac
}
