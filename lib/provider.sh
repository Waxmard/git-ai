#!/bin/bash
# provider.sh - provider/model selection and run_provider dispatch (sourced via lib/ai-common.sh).

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

# pick_via_fzf TOOL
# Launch fzf over list_options output, echo the selected value (text before
# the '|' delimiter). Returns non-zero if fzf is missing, GIT_AI_NO_FZF is
# set, or the user cancels. Caller is responsible for the tty check — this
# function is invoked inside $(...) so its own stdout is never a tty.
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

# generateContent request body, shared by the AI Studio and Vertex endpoints —
# same payload shape, different host and auth.
_gemini_request_body() {
  GIT_AI_PROMPT="$1" GIT_AI_INPUT="$2" "${GIT_AI_PYTHON:-python3}" -c '
import json, os
print(json.dumps({
  "systemInstruction": {"parts": [{"text": os.environ["GIT_AI_PROMPT"]}]},
  "contents": [{"role": "user", "parts": [{"text": os.environ["GIT_AI_INPUT"]}]}]
}))'
}

# Thinking models return their reasoning as parts flagged `thought`, so the
# answer is not always parts[0] — join every non-thought text part.
_extract_gemini_text() {
  "${GIT_AI_PYTHON:-python3}" -c '
import json, sys
data = json.loads(sys.stdin.read())
candidates = data.get("candidates") or [{}]
parts = (candidates[0].get("content") or {}).get("parts") or []
text = "".join(p.get("text", "") for p in parts if not p.get("thought"))
if not text.strip():
    sys.exit(1)
print(text)
'
}

# Print the API's own `error.message` from a JSON error body, empty when the
# body isn't the shape we expect.
_api_error_message() {
  "${GIT_AI_PYTHON:-python3}" -c '
import json, sys
try:
    print((json.loads(sys.stdin.read()).get("error") or {}).get("message", ""))
except Exception:
    pass
' 2>/dev/null
}

_run_gemini_api() {
  local model="$1" prompt="$2" input="$3" key="$4"
  local body cfg response st http detail
  body=$(_gemini_request_body "$prompt" "$input") || die "Failed to build Gemini API request"
  cfg=$(mktemp "${TMPDIR:-/tmp}/git-ai-curl.XXXXXX") || die "failed to create curl config file"
  trap 'rm -f "$cfg"' EXIT
  # The key is a URL parameter, so the whole URL goes in the curl config file
  # rather than argv (keeps the key out of `ps`).
  printf 'url = "https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent?key=%s"\n' \
    "$model" "$key" >"$cfg"
  # No -f: a rejected key or unknown model is a 4xx whose body explains why, and
  # this is the path a stale key lands on.
  response=$(curl -s -K "$cfg" -H "content-type: application/json" -d "$body" -w '\n%{http_code}')
  st=$?
  rm -f "$cfg"
  [[ $st -eq 0 ]] || die "Gemini API request failed"
  http="${response##*$'\n'}"
  response="${response%$'\n'*}"
  if [[ "$http" != 2* ]]; then
    detail=$(_api_error_message <<<"$response")
    die "Gemini API request failed (HTTP ${http})${detail:+: $detail}"
  fi
  _extract_gemini_text <<<"$response" || die "Failed to parse Gemini API response"
}

# Linux caps a SINGLE argv string at MAX_ARG_STRLEN (32 pages = 131072 bytes),
# separately from ARG_MAX, and execve fails with E2BIG above it — a branch diff
# well inside git-ai's own GIT_AI_MAX_DIFF_BYTES ceiling can exceed that. macOS
# has no per-argument cap, but the threshold is uniform so behaviour doesn't
# differ by platform.
AGY_MAX_INLINE_PROMPT="${AGY_MAX_INLINE_PROMPT:-120000}"

# _agy_prompt_arg PROMPT INPUT
# Print the value for agy's -p flag. Past the argv limit the payload is staged
# in a temp file and printed as `@path`, which agy expands client-side (still
# one turn — not a tool call the model has to make). An `@` answer is therefore
# the caller's signal that it owns a temp file to remove.
_agy_prompt_arg() {
  local payload bytes staged
  payload=$(printf '%s\n\n%s' "$1" "$2")
  # ${#payload} counts characters; execve counts bytes, and a multi-byte diff
  # would slip past a character-based check.
  bytes=$(printf '%s' "$payload" | LC_ALL=C wc -c)
  if ((bytes <= AGY_MAX_INLINE_PROMPT)); then
    printf '%s' "$payload"
    return 0
  fi
  staged=$(mktemp "${TMPDIR:-/tmp}/git-ai-agy-prompt.XXXXXX") || return 1
  printf '%s' "$payload" >"$staged" || return 1
  printf '@%s' "$staged"
}

_vertex_endpoint() {
  local project="$1" region="$2" publisher="$3" model="$4" method="$5"
  local host
  [[ "$region" == "global" ]] && host="aiplatform.googleapis.com" \
                               || host="${region}-aiplatform.googleapis.com"
  printf 'https://%s/v1/projects/%s/locations/%s/publishers/%s/models/%s:%s\n' \
    "$host" "$project" "$region" "$publisher" "$model" "$method"
}

# Thinking-capable models put a `thinking` block first, so content[0] is not
# always the answer — concatenate every text block instead.
_extract_anthropic_text() {
  "${GIT_AI_PYTHON:-python3}" -c '
import json, sys
data = json.loads(sys.stdin.read())
text = "".join(
  block.get("text", "")
  for block in data.get("content", [])
  if block.get("type") == "text"
)
if not text.strip():
    sys.exit(1)
print(text)
'
}

_run_vertex_anthropic_api() {
  local model="$1" prompt="$2" input="$3" project="$4" region="$5" account="${6:-}"
  local token body url curl_cfg response
  token=$(_vertex_access_token "$account") ||
    die "Vertex auth: gcloud print-access-token failed."
  body=$(GIT_AI_PROMPT="$prompt" GIT_AI_INPUT="$input" "${GIT_AI_PYTHON:-python3}" -c '
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
  _extract_anthropic_text <<<"$response" || die "Failed to parse Vertex Anthropic response"
}

_run_vertex_gemini_api() {
  local model="$1" prompt="$2" input="$3" project="$4" region="$5" account="${6:-}"
  local token body url curl_cfg response
  token=$(_vertex_access_token "$account") ||
    die "Vertex auth: gcloud print-access-token failed."
  body=$(_gemini_request_body "$prompt" "$input") || die "Failed to build Vertex Gemini request"
  url=$(_vertex_endpoint "$project" "$region" "google" "$model" "generateContent")
  curl_cfg=$(mktemp "${TMPDIR:-/tmp}/git-ai-curl.XXXXXX") || die "failed to create curl config file"
  trap 'rm -f "$curl_cfg"' EXIT
  printf 'header = "Authorization: Bearer %s"\n' "$token" > "$curl_cfg"
  response=$(curl -sf -K "$curl_cfg" -H "content-type: application/json" -d "$body" "$url")
  local curl_status=$?
  rm -f "$curl_cfg"
  [[ $curl_status -eq 0 ]] || die "Vertex Gemini API request failed"
  _extract_gemini_text <<<"$response" || die "Failed to parse Vertex Gemini response"
}

_run_anthropic_api() {
  local model="$1"
  local prompt="$2"
  local input="$3"
  local key="$4"
  local body response curl_cfg
  body=$(GIT_AI_MODEL="$model" GIT_AI_PROMPT="$prompt" GIT_AI_INPUT="$input" \
    "${GIT_AI_PYTHON:-python3}" -c '
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
  printf 'header = "x-api-key: %s"\n' "$key" > "$curl_cfg"
  response=$(curl -sf \
    -K "$curl_cfg" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d "$body" \
    "https://api.anthropic.com/v1/messages")
  local curl_status=$?
  rm -f "$curl_cfg"
  [[ $curl_status -eq 0 ]] || die "Anthropic API request failed"
  _extract_anthropic_text <<<"$response" || die "Failed to parse Anthropic API response"
}

_run_openai_api() {
  local model="$1"
  local prompt="$2"
  local input="$3"
  local key="$4"
  local body response curl_cfg
  body=$(GIT_AI_MODEL="$model" GIT_AI_PROMPT="$prompt" GIT_AI_INPUT="$input" \
    "${GIT_AI_PYTHON:-python3}" -c '
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
  printf 'header = "Authorization: Bearer %s"\n' "$key" > "$curl_cfg"
  response=$(curl -sf \
    -K "$curl_cfg" \
    -H "content-type: application/json" \
    -d "$body" \
    "https://api.openai.com/v1/chat/completions")
  local curl_status=$?
  rm -f "$curl_cfg"
  [[ $curl_status -eq 0 ]] || die "OpenAI API request failed"
  "${GIT_AI_PYTHON:-python3}" -c '
import json, sys
data = json.loads(sys.stdin.read())
print(data["choices"][0]["message"]["content"])
' <<<"$response" || die "Failed to parse OpenAI API response"
}

# run_provider TOOL_NAME PROVIDER PROMPT INPUT [MODEL]
# Runs the given LLM provider with the prompt and input, emitting its raw text;
# the caller pipes that through the Python parse layer.
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
      # --max-turns must exceed 1: reasoning models spend a turn thinking, so a
      # cap of 1 aborts with "Reached max turns" before any text is emitted.
      claude -p "$prompt" --max-turns 3 --model "$model" <<<"$input" ||
        die "Claude generation failed"
      ;;
    anthropic-api)
      local anthropic_key
      anthropic_key=$(resolve_api_key anthropic-api-key ANTHROPIC_API_KEY) ||
        die "Anthropic API auth not found. Set ANTHROPIC_API_KEY or store 'anthropic-api-key' in your keychain."
      _run_anthropic_api "$model" "$prompt" "$input" "$anthropic_key" ||
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
        _run_vertex_anthropic_api "$model" "$prompt" "$input" "$vertex_project" "$vertex_region" "$vertex_account"
      else
        _run_vertex_gemini_api "$model" "$prompt" "$input" "$vertex_project" "$vertex_region" "$vertex_account"
      fi
      ;;
    gemini-api)
      local gemini_api_key
      gemini_api_key=$(resolve_gemini_api_key) ||
        die "Gemini API auth not found. Set GEMINI_API_KEY or store 'gemini-api-key' in your keychain."
      _run_gemini_api "$model" "$prompt" "$input" "$gemini_api_key"
      ;;
    antigravity)
      command -v agy >/dev/null 2>&1 ||
        die "Antigravity auth requires the Antigravity CLI. See: https://antigravity.google"
      local agy_err_file agy_status agy_error agy_arg agy_prompt_file=""
      agy_err_file=$(mktemp "${TMPDIR:-/tmp}/git-ai-agy.XXXXXX") ||
        die "failed to create temporary error file"
      # agy ignores stdin, so prompt and input both ride on -p.
      agy_arg=$(_agy_prompt_arg "$prompt" "$input") || die "failed to stage the Antigravity prompt"
      # An @-prefixed arg means the payload was staged past the argv limit, and
      # that file is ours to clean up.
      [[ "$agy_arg" == @* ]] && agy_prompt_file="${agy_arg#@}"
      trap 'rm -f "$agy_err_file" ${agy_prompt_file:+"$agy_prompt_file"}' EXIT
      # --disable-slash-commands stops a diff line opening with `/` from being
      # expanded as a slash command.
      output=$(agy -p "$agy_arg" \
        --model "$model" --output-format text --disable-slash-commands 2>"$agy_err_file")
      agy_status=$?
      agy_error=$(<"$agy_err_file")
      rm -f "$agy_err_file" ${agy_prompt_file:+"$agy_prompt_file"}
      if [[ $agy_status -ne 0 ]]; then
        [[ -n "$agy_error" ]] && die "Antigravity generation failed: $agy_error"
        die "Antigravity generation failed"
      fi
      # A tool call agy could not get approval for is soft-denied: exit 0, no
      # text, and the reason only on stderr — so surface stderr here too.
      [[ -n "$output" ]] ||
        die "Antigravity generation failed: empty response${agy_error:+ — $agy_error}"
      printf '%s\n' "$output"
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
      printf '%s\n' "$output"
      ;;
    openai-api)
      local openai_key
      openai_key=$(resolve_api_key openai-api-key OPENAI_API_KEY) ||
        die "OpenAI API auth not found. Set OPENAI_API_KEY or store 'openai-api-key' in your keychain."
      _run_openai_api "$model" "$prompt" "$input" "$openai_key" ||
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
