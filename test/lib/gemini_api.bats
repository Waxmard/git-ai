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

# Write a `curl` stub replying with BODY and HTTP code $1. It also saves its
# argv and any `@file` payload so tests can assert on the staged request body.
write_curl_stub() {
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s\\n" "$@" >"%s/curl-args"\n' "$TEST_DIR"
    printf 'for a in "$@"; do case $a in @*) cp "${a#@}" "%s/curl-body";; esac; done\n' "$TEST_DIR"
    printf 'cat <<'\''BODY_EOF'\''\n'
    cat
    printf 'BODY_EOF\nprintf %s\n' "$1"
  } >"${STUB_BIN}/curl"
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

# Linux caps a single argv/env string at 131072 bytes, so a payload this size
# would fail execve if it rode either instead of a staged file.
@test "_run_gemini_api: an over-argv-limit input reaches curl as a file" {
  write_curl_stub 200 <<'JSON'
{"candidates":[{"content":{"parts":[{"text":"feat: big change"}]}}]}
JSON
  local big
  big=$(head -c 200000 /dev/zero | tr '\0' 'x')
  PATH="${STUB_BIN}:$PATH" run _run_gemini_api "gemini-test" "prompt" "$big" "k"
  assert_success
  assert_output "feat: big change"
  run grep -qx -- '--data-binary' "${TEST_DIR}/curl-args"
  assert_success
  [ "$(wc -c <"${TEST_DIR}/curl-body")" -gt 200000 ]
}

@test "_run_gemini_api: a 200 with no usable text fails rather than emitting nothing" {
  write_curl_stub 200 <<'JSON'
{"candidates":[{"content":{"parts":[{"text":"thinking","thought":true}]}}]}
JSON
  PATH="${STUB_BIN}:$PATH" run _run_gemini_api "gemini-test" "prompt" "input" "k"
  assert_failure
  assert_output --partial "Failed to parse Gemini API response"
}
