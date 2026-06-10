#!/bin/bash
# provider.sh - provider/model selection and run_provider dispatch (sourced via lib/ai-common.sh).

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
