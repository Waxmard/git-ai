#!/usr/bin/env bats
load '../helpers/common'

setup() {
  load_bats_libs
  TEST_DIR="$(mktemp -d)"
  STUB_BIN="${TEST_DIR}/bin"
  mkdir -p "$STUB_BIN"
  GCLOUD_LOG="${TEST_DIR}/gcloud.log"
  export GCLOUD_LOG
  source "${REPO_ROOT}/lib/ai-common.sh"
}

teardown() {
  rm -rf "$TEST_DIR"
}

write_adc_gcloud_stub() {
  cat >"${STUB_BIN}/gcloud" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GCLOUD_LOG"
if [[ "$1 $2 $3" == "auth application-default print-access-token" ]]; then
  printf 'adc-token\n'
  exit 0
fi
if [[ "$1 $2" == "auth print-access-token" ]]; then
  exit 42
fi
exit 1
EOF
  chmod +x "${STUB_BIN}/gcloud"
}

write_old_token_only_gcloud_stub() {
  cat >"${STUB_BIN}/gcloud" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GCLOUD_LOG"
if [[ "$1 $2" == "auth print-access-token" ]]; then
  printf 'user-token\n'
  exit 0
fi
exit 1
EOF
  chmod +x "${STUB_BIN}/gcloud"
}

write_curl_stub() {
  cat >"${STUB_BIN}/curl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *anthropic*) printf '{"content":[{"text":"anthropic ok"}]}\n' ;;
  *) printf '{"candidates":[{"content":{"parts":[{"text":"gemini ok"}]}}]}\n' ;;
esac
EOF
  chmod +x "${STUB_BIN}/curl"
}

@test "_vertex_access_token uses application-default ADC token command" {
  write_adc_gcloud_stub

  PATH="${STUB_BIN}:$PATH" run _vertex_access_token

  assert_success
  assert_output "adc-token"
  assert_equal "$(cat "$GCLOUD_LOG")" "auth application-default print-access-token"
}

@test "_gemini_has_adc rejects active-user gcloud auth tokens" {
  write_old_token_only_gcloud_stub

  PATH="${STUB_BIN}:$PATH" run _gemini_has_adc

  assert_failure
  assert_equal "$(cat "$GCLOUD_LOG")" "auth application-default print-access-token"
}

@test "Vertex Gemini and Anthropic API calls mint ADC tokens" {
  write_adc_gcloud_stub
  write_curl_stub

  PATH="${STUB_BIN}:$PATH" run _run_vertex_gemini_api "gemini-test" "prompt" "input" "proj" "global"
  assert_success
  assert_output "gemini ok"

  : >"$GCLOUD_LOG"
  PATH="${STUB_BIN}:$PATH" run _run_vertex_anthropic_api "claude-test" "prompt" "input" "proj" "global"
  assert_success
  assert_output "anthropic ok"
  assert_equal "$(cat "$GCLOUD_LOG")" "auth application-default print-access-token"
}
