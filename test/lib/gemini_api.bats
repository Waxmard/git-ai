#!/usr/bin/env bats
load '../helpers/common'

# Exercises the AI Studio generateContent path with a stubbed `curl`: the key
# never leaves the curl config file, so the stub asserts on the request body and
# replays canned responses (including the `\n<http_code>` -w suffix).
setup() {
  load_bats_libs
  TEST_DIR="$(mktemp -d)"
  STUB_BIN="${TEST_DIR}/bin"
  mkdir -p "$STUB_BIN"
  source "${REPO_ROOT}/lib/ai-common.sh"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# Write a `curl` stub replying with BODY and HTTP code $1.
write_curl_stub() {
  { printf '#!/usr/bin/env bash\ncat <<'\''BODY_EOF'\''\n'; cat; printf 'BODY_EOF\nprintf %s\n' "$1"; } \
    >"${STUB_BIN}/curl"
  chmod +x "${STUB_BIN}/curl"
}

@test "_run_gemini_api: joins text parts and skips the thinking ones" {
  write_curl_stub 200 <<'JSON'
{"candidates":[{"content":{"parts":[
  {"text":"reasoning about it","thought":true},
  {"text":"feat: add thing"},
  {"text":"\n\nBody line."}
]}}]}
JSON
  PATH="${STUB_BIN}:$PATH" run _run_gemini_api "gemini-test" "prompt" "input" "k"
  assert_success
  assert_output "feat: add thing

Body line."
  refute_output --partial "reasoning about it"
}

@test "_run_gemini_api: a rejected key reports the API's own message" {
  write_curl_stub 400 <<'JSON'
{"error":{"code":400,"message":"API key not valid. Please pass a valid API key."}}
JSON
  PATH="${STUB_BIN}:$PATH" run _run_gemini_api "gemini-test" "prompt" "input" "stale"
  assert_failure
  assert_output --partial "HTTP 400"
  assert_output --partial "API key not valid"
}

@test "_run_gemini_api: a 200 with no usable text fails rather than emitting nothing" {
  write_curl_stub 200 <<'JSON'
{"candidates":[{"content":{"parts":[{"text":"thinking","thought":true}]}}]}
JSON
  PATH="${STUB_BIN}:$PATH" run _run_gemini_api "gemini-test" "prompt" "input" "k"
  assert_failure
  assert_output --partial "Failed to parse Gemini API response"
}
