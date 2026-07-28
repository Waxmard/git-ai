#!/usr/bin/env bats
load '../helpers/common'

setup() {
  load_bats_libs
  TEST_DIR="$(mktemp -d)"
  STUB_BIN="${TEST_DIR}/bin"
  mkdir -p "$STUB_BIN"
  CURL_CFG="${TEST_DIR}/cfg.copy"
  export CURL_CFG
  cat >"${STUB_BIN}/curl" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-K" ]]; then
    cat "$2" >"$CURL_CFG"
    shift 2
    continue
  fi
  shift
done
printf '200'
EOF
  chmod +x "${STUB_BIN}/curl"
  PATH="${STUB_BIN}:${PATH}"
  unset GIT_AI_NO_KEY_PROBE
  source "${REPO_ROOT}/lib/ai-common.sh"
  source "${REPO_ROOT}/lib/setup.sh"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "_setup_probe_key: escapes quotes and backslashes in the curl config" {
  run _setup_probe_key anthropic-api 'ab"c\d'
  assert_success
  run cat "$CURL_CFG"
  assert_line 'header = "x-api-key: ab\"c\\d"'
}

@test "_setup_probe_key: a plain key is written verbatim" {
  run _setup_probe_key openai-api 'sk-plain-123'
  assert_success
  run cat "$CURL_CFG"
  assert_line 'header = "Authorization: Bearer sk-plain-123"'
}
