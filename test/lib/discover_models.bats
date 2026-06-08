#!/usr/bin/env bats
load '../helpers/common'

# Exercises the live model-discovery layer with a stub PATH: `curl` and `gcloud`
# are replaced by fixtures so the JSON parsing / filtering and the on-disk cache
# can be tested deterministically offline.
setup() {
  load_bats_libs
  source "${REPO_ROOT}/lib/ai-common.sh"

  TEST_XDG="$(mktemp -d)"
  export XDG_CONFIG_HOME="$TEST_XDG"
  CACHE="${TEST_XDG}/git-ai/models-cache"
  mkdir -p "$CACHE"

  STUB="$(mktemp -d)"
  export PATH="${STUB}:${PATH}"
  unset GEMINI_API_KEY ANTHROPIC_API_KEY OPENAI_API_KEY
}

teardown() {
  rm -rf "$TEST_XDG" "$STUB"
  unset XDG_CONFIG_HOME GEMINI_API_KEY ANTHROPIC_API_KEY OPENAI_API_KEY
}

# Write a `curl` stub that prints FIXTURE (ignoring all args) and exits 0.
stub_curl_ok() {
  { printf '#!/bin/sh\ncat <<'\''FIXTURE_EOF'\''\n'; cat; printf 'FIXTURE_EOF\n'; } >"${STUB}/curl"
  chmod +x "${STUB}/curl"
}

stub_curl_fail() {
  printf '#!/bin/sh\nexit 22\n' >"${STUB}/curl"
  chmod +x "${STUB}/curl"
}

# --- cache behaviour ---

@test "discover_models: serves a fresh cache without fetching" {
  printf 'model-a\nmodel-b\n' >"${CACHE}/gemini-api.list"
  stub_curl_fail  # must not be consulted
  run discover_models gemini-api
  assert_success
  assert_line --index 0 "model-a"
  assert_line --index 1 "model-b"
}

@test "discover_models: --refresh bypasses the cache and refetches" {
  printf 'stale-model\n' >"${CACHE}/gemini-api.list"
  export GEMINI_API_KEY=x
  stub_curl_ok <<'JSON'
{"models":[{"name":"models/fresh-model","supportedGenerationMethods":["generateContent"]}]}
JSON
  run discover_models gemini-api --refresh
  assert_success
  assert_output "fresh-model"
}

@test "discover_models: serves a stale cache when the fetch fails" {
  printf 'cached-model\n' >"${CACHE}/gemini-api.list"
  touch -t 202001010000 "${CACHE}/gemini-api.list"  # force stale
  export GIT_AI_MODELS_TTL_MIN=1
  stub_curl_fail
  run discover_models gemini-api
  assert_success
  assert_output "cached-model"
}

@test "discover_models: caches a successful fetch to disk" {
  export GEMINI_API_KEY=x
  stub_curl_ok <<'JSON'
{"models":[{"name":"models/gemini-x","supportedGenerationMethods":["generateContent"]}]}
JSON
  run discover_models gemini-api
  assert_success
  assert_output "gemini-x"
  [ -s "${CACHE}/gemini-api.list" ]
  run cat "${CACHE}/gemini-api.list"
  assert_output "gemini-x"
}

@test "discover_models: returns non-zero when nothing can be discovered" {
  stub_curl_fail
  run discover_models gemini-api
  assert_failure
  assert_output ""
}

# --- per-provider fetch parsing / filtering ---

@test "_fetch_models_gemini_api: keeps only generateContent models, strips prefix" {
  export GEMINI_API_KEY=x
  stub_curl_ok <<'JSON'
{"models":[
  {"name":"models/gemini-3.5-pro","supportedGenerationMethods":["generateContent","countTokens"]},
  {"name":"models/embedding-001","supportedGenerationMethods":["embedContent"]},
  {"baseModelId":"gemini-3.5-flash","name":"models/gemini-3.5-flash-002","supportedGenerationMethods":["generateContent"]}
]}
JSON
  run _fetch_models_gemini_api
  assert_success
  assert_line "gemini-3.5-pro"
  assert_line "gemini-3.5-flash"
  refute_line --partial "embedding"
}

@test "_fetch_models_anthropic_api: lists data[].id in order" {
  export ANTHROPIC_API_KEY=x
  stub_curl_ok <<'JSON'
{"data":[{"id":"claude-opus-4-6","type":"model"},{"id":"claude-haiku-4-5","type":"model"}]}
JSON
  run _fetch_models_anthropic_api
  assert_success
  assert_line --index 0 "claude-opus-4-6"
  assert_line --index 1 "claude-haiku-4-5"
}

@test "_fetch_models_openai_api: filters out non-chat models" {
  export OPENAI_API_KEY=x
  stub_curl_ok <<'JSON'
{"data":[
  {"id":"gpt-5.4"},
  {"id":"gpt-5.4-mini"},
  {"id":"text-embedding-3-large"},
  {"id":"tts-1"},
  {"id":"dall-e-3"},
  {"id":"o3"}
]}
JSON
  run _fetch_models_openai_api
  assert_success
  assert_line "gpt-5.4"
  assert_line "gpt-5.4-mini"
  assert_line "o3"
  refute_line "text-embedding-3-large"
  refute_line "tts-1"
  refute_line "dall-e-3"
}

@test "_fetch_models_vertex: family filter + text-only, strips path and non-text variants" {
  # gcloud stub: any invocation (token mint + `config get-value project` for the
  # quota project) succeeds.
  printf '#!/bin/sh\necho fake\n' >"${STUB}/gcloud"
  chmod +x "${STUB}/gcloud"
  stub_curl_ok <<'JSON'
{"publisherModels":[
  {"name":"publishers/google/models/gemini-3.5-pro"},
  {"name":"publishers/google/models/imagen-3.0"},
  {"name":"publishers/google/models/gemini-embedding-001"},
  {"name":"publishers/google/models/gemini-2.5-flash-tts"},
  {"name":"publishers/google/models/gemini-3.5-flash"}
]}
JSON
  run _fetch_models_vertex vertex-gemini google
  assert_success
  assert_line "gemini-3.5-pro"
  assert_line "gemini-3.5-flash"
  refute_line "imagen-3.0"            # wrong family
  refute_line "gemini-embedding-001"  # non-text variant
  refute_line "gemini-2.5-flash-tts"  # non-text variant
}
