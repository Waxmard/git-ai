#!/usr/bin/env bats
load '../helpers/common'

setup() {
  load_bats_libs
  TEST_DIR="$(mktemp -d)"
  STUB_BIN="${TEST_DIR}/bin"
  mkdir -p "$STUB_BIN"
  # Isolate from the developer's real env + ~/.config so lookups are deterministic.
  unset ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY
  export XDG_CONFIG_HOME="$TEST_DIR"
  source "${REPO_ROOT}/lib/ai-common.sh"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# A `security` stub that returns a fixed secret only for service "test-service".
write_security_stub() {
  cat >"${STUB_BIN}/security" <<'EOF'
#!/usr/bin/env bash
svc=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  [[ "${args[i]}" == "-s" ]] && svc="${args[i + 1]}"
done
[[ "$svc" == "test-service" ]] && { printf 'secret-from-keychain\n'; exit 0; }
exit 44
EOF
  chmod +x "${STUB_BIN}/security"
}

@test "resolve_api_key returns the env var when set" {
  export TEST_SVC_KEY="env-value"
  run resolve_api_key test-service TEST_SVC_KEY
  assert_success
  assert_output "env-value"
}

@test "resolve_api_key falls back to the macOS keychain when env is unset" {
  write_security_stub
  unset TEST_SVC_KEY
  PATH="${STUB_BIN}:$PATH" run resolve_api_key test-service TEST_SVC_KEY
  assert_success
  assert_output "secret-from-keychain"
}

@test "resolve_api_key returns non-zero when nothing is found" {
  unset TEST_SVC_KEY
  # Empty PATH: no security/secret-tool/pass/kwallet available to consult.
  PATH="$STUB_BIN" run resolve_api_key missing-service TEST_SVC_KEY
  assert_failure
}

@test "resolve_gemini_api_key delegates to resolve_api_key via the env var" {
  export GEMINI_API_KEY="gemini-env"
  run resolve_gemini_api_key
  assert_success
  assert_output "gemini-env"
}
