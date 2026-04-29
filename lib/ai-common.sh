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
  get_last_choice "${1}-last-provider" "${2:-}" "vertex-gemini|vertex-anthropic|gemini-api|claude-code|anthropic-api|codex|openai-api"
}

save_last_provider() {
  save_last_choice "${1}-last-provider" "$2"
}

get_last_model() {
  local tool_name="$1"
  local provider="$2"
  local fallback="$3"
  local valid
  valid=$(models_for_provider "$provider" | paste -sd'|' -)
  get_last_choice "${tool_name}-${provider}-last-model" "$fallback" "$valid"
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

resolve_gemini_api_key() {
  local keychain_account
  local key

  if [[ -n "${GEMINI_API_KEY:-}" ]]; then
    printf '%s\n' "$GEMINI_API_KEY"
    return 0
  fi

  # macOS Keychain
  if command -v security >/dev/null 2>&1; then
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
  fi

  # Linux: libsecret / GNOME Keyring
  if command -v secret-tool >/dev/null 2>&1; then
    key=$(secret-tool lookup service gemini-api-key 2>/dev/null) && [[ -n "$key" ]] && {
      printf '%s\n' "$key"
      return 0
    }
  fi

  # Linux: pass (password-store)
  if command -v pass >/dev/null 2>&1; then
    key=$(pass show gemini-api-key 2>/dev/null) && [[ -n "$key" ]] && {
      printf '%s\n' "$key"
      return 0
    }
  fi

  # Linux: KDE Wallet
  if command -v kwallet-query >/dev/null 2>&1; then
    key=$(kwallet-query kdewallet -r gemini-api-key 2>/dev/null) && [[ -n "$key" ]] && {
      printf '%s\n' "$key"
      return 0
    }
  fi

  return 1
}

_gemini_has_adc() {
  if [[ -n "$(_vertex_access_token)" ]]; then
    return 0
  fi
  return 1
}

_vertex_access_token() {
  command -v gcloud >/dev/null 2>&1 || return 1
  gcloud auth application-default print-access-token 2>/dev/null
}

provider_display_name() {
  case $1 in
    vertex-gemini)    echo "Vertex AI (Gemini)" ;;
    vertex-anthropic) echo "Vertex AI (Anthropic)" ;;
    gemini-api)    echo "Gemini API" ;;
    claude-code)   echo "Claude Code" ;;
    anthropic-api) echo "Anthropic API" ;;
    codex)         echo "Codex CLI" ;;
    openai-api)    echo "OpenAI API" ;;
    last)          echo "Reuse last message" ;;
  esac
}

provider_is_valid() {
  case $1 in
    vertex-gemini|vertex-anthropic|gemini-api|claude-code|anthropic-api|codex|openai-api|last) return 0 ;;
    *) return 1 ;;
  esac
}

provider_family() {
  case $1 in
    vertex-gemini|gemini-api) printf '%s\n' "gemini" ;;
    vertex-anthropic|claude-code|anthropic-api) printf '%s\n' "claude" ;;
    codex|openai-api) printf '%s\n' "openai" ;;
    *) return 1 ;;
  esac
}

models_for_family() {
  case $1 in
    claude)
      printf '%s\n' \
        "claude-haiku-4-5-20251001" \
        "claude-sonnet-4-6" \
        "claude-opus-4-6"
      ;;
    gemini)
      printf '%s\n' \
        "gemini-3.1-flash-lite-preview" \
        "gemini-3.1-pro-preview"
      ;;
    openai)
      printf '%s\n' \
        "gpt-5.4-mini" \
        "gpt-5.4"
      ;;
  esac
}

models_for_provider() {
  case $1 in
    vertex-gemini)
      models_for_family gemini
      ;;
    vertex-anthropic)
      models_for_family claude
      ;;
    gemini-api)
      models_for_family gemini
      ;;
    claude-code|anthropic-api)
      models_for_family claude
      ;;
    codex|openai-api)
      models_for_family openai
      ;;
    *) return 1 ;;
  esac
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
  done < <(models_for_provider "$provider")
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

# Parse the user options file and emit one "provider:model" line per enabled
# combo. Empty sections drop that provider entirely. Unknown provider section
# names are silently ignored. Custom model IDs (not in the shipped catalog)
# are passed through as-is.
parse_user_options() {
  local path
  path=$(user_options_path)
  [[ -r "$path" ]] || return 0

  local line trimmed section=""
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
        section=""
      fi
      continue
    fi

    [[ -n "$section" ]] || continue
    printf '%s:%s\n' "$section" "$trimmed"
  done <"$path"
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

  local provider model display short
  if [[ -n "$user_entries" ]]; then
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
      done < <(models_for_provider "$provider")
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
    label=$(printf '%s\n' "$table" | awk -F'\t' -v v="$entry" '$1 == v {print $2; exit}')
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

default_model_for_provider() {
  local tool_name="$1"
  local provider="$2"
  local family
  family=$(provider_family "$provider") || return 1

  case "${tool_name}:${family}" in
    pr:claude) printf '%s\n' "claude-opus-4-6" ;;
    pr:gemini) printf '%s\n' "gemini-3.1-pro-preview" ;;
    pr:openai) printf '%s\n' "gpt-5.4" ;;
    *:claude) printf '%s\n' "claude-haiku-4-5-20251001" ;;
    *:gemini) printf '%s\n' "gemini-3.1-flash-lite-preview" ;;
    *:openai) printf '%s\n' "gpt-5.4-mini" ;;
  esac
}

resolve_model() {
  local tool_name="$1"
  local provider="$2"
  local model="${3:-}"

  if [[ -n "$model" ]]; then
    if models_for_provider "$provider" | grep -Fxq "$model"; then
      printf '%s\n' "$model"
      return
    fi
    # Permit custom model IDs declared in the user options file — this lets
    # the config add future model IDs without a git-ai release.
    if parse_user_options | grep -Fxq "${provider}:${model}"; then
      printf '%s\n' "$model"
      return
    fi
    die "unknown model '$model' for provider '$provider'"
  fi

  default_model_for_provider "$tool_name" "$provider"
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
  local model="$1" prompt="$2" input="$3" project="$4" region="$5"
  local token body url curl_cfg response
  token=$(_vertex_access_token) ||
    die "Vertex auth: gcloud auth application-default print-access-token failed."
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
  local model="$1" prompt="$2" input="$3" project="$4" region="$5"
  local token body url curl_cfg response
  token=$(_vertex_access_token) ||
    die "Vertex auth: gcloud auth application-default print-access-token failed."
  body=$(GIT_AI_PROMPT="$prompt" GIT_AI_INPUT="$input" python3 -c '
import json, os
print(json.dumps({
  "systemInstruction": {"parts": [{"text": os.environ["GIT_AI_PROMPT"]}]},
  "contents": [{"role": "user", "parts": [{"text": os.environ["GIT_AI_INPUT"]}]}]
}))') || die "Failed to build Vertex Gemini request"
  url=$(_vertex_endpoint "$project" "$region" "google" "$model" "generateContent")
  curl_cfg=$(mktemp "${TMPDIR:-/tmp}/git-ai-curl.XXXXXX") || die "failed to create curl config file"
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
  local model
  model=$(resolve_model "$tool_name" "$provider" "$selected_model")

  case $provider in
    claude-code)
      command -v claude >/dev/null 2>&1 ||
        die "Claude Code auth requires the Claude Code CLI. See: https://claude.ai/code"
      claude -p "$prompt" --max-turns 1 --model "$model" <<<"$input" | strip_fences ||
        die "Claude generation failed"
      ;;
    anthropic-api)
      [[ -n "${ANTHROPIC_API_KEY:-}" ]] ||
        die "Anthropic API auth requires ANTHROPIC_API_KEY."
      _run_anthropic_api "$model" "$prompt" "$input" | strip_fences ||
        die "Anthropic API generation failed"
      ;;
    vertex-gemini|vertex-anthropic)
      load_google_env
      _gemini_has_adc ||
        die "Vertex auth not found. Configure gcloud ADC or GOOGLE_APPLICATION_CREDENTIALS."
      local vertex_project vertex_region
      vertex_project="${GOOGLE_VERTEX_PROJECT:-${GOOGLE_CLOUD_PROJECT:-}}"
      vertex_region="${VERTEX_LOCATION:-${GOOGLE_VERTEX_LOCATION:-${GOOGLE_CLOUD_LOCATION:-us-central1}}}"
      [[ -n "$vertex_project" ]] ||
        die "Vertex auth requires GOOGLE_CLOUD_PROJECT or GOOGLE_VERTEX_PROJECT."
      if [[ "$provider" == "vertex-anthropic" ]]; then
        _run_vertex_anthropic_api "$model" "$prompt" "$input" "$vertex_project" "$vertex_region" | strip_fences
      else
        _run_vertex_gemini_api "$model" "$prompt" "$input" "$vertex_project" "$vertex_region" | strip_fences
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
      [[ -n "${OPENAI_API_KEY:-}" ]] ||
        die "OpenAI API auth requires OPENAI_API_KEY."
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
