#!/usr/bin/env bats
load '../helpers/common'

setup() {
  load_bats_libs
  TEST_DIR="$(mktemp -d)"
  STUB_BIN="${TEST_DIR}/bin"
  mkdir -p "$STUB_BIN"
  SECURITY_LOG="${TEST_DIR}/security.log"
  export SECURITY_LOG
  source "${REPO_ROOT}/lib/ai-common.sh"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# --- provider_key_meta -----------------------------------------------------

@test "provider_key_meta: anthropic-api maps to service + env var" {
  run provider_key_meta anthropic-api
  assert_success
  assert_output "anthropic-api-key ANTHROPIC_API_KEY"
}

@test "provider_key_meta: gemini-api maps to service + env var" {
  run provider_key_meta gemini-api
  assert_success
  assert_output "gemini-api-key GEMINI_API_KEY"
}

@test "provider_key_meta: CLI/vertex providers are not key-based" {
  run provider_key_meta claude-code
  assert_failure
  run provider_key_meta vertex-gemini
  assert_failure
}

# --- shell_rc_path ---------------------------------------------------------

@test "shell_rc_path: zsh resolves to ~/.zshrc" {
  HOME="$TEST_DIR" run shell_rc_path zsh
  assert_success
  assert_output "${TEST_DIR}/.zshrc"
}

@test "shell_rc_path: zsh honors ZDOTDIR" {
  HOME="$TEST_DIR" ZDOTDIR="${TEST_DIR}/zdot" run shell_rc_path zsh
  assert_success
  assert_output "${TEST_DIR}/zdot/.zshrc"
}

@test "shell_rc_path: bash resolves to ~/.bashrc" {
  HOME="$TEST_DIR" run shell_rc_path bash
  assert_success
  assert_output "${TEST_DIR}/.bashrc"
}

@test "shell_rc_path: fish resolves to its config" {
  HOME="$TEST_DIR" run shell_rc_path fish
  assert_success
  assert_output "${TEST_DIR}/.config/fish/config.fish"
}

@test "shell_rc_path: unknown shell falls back to ~/.profile" {
  HOME="$TEST_DIR" run shell_rc_path tcsh
  assert_success
  assert_output "${TEST_DIR}/.profile"
}

# --- format_key_export -----------------------------------------------------

@test "format_key_export: POSIX shells use export with single quotes" {
  run format_key_export MY_KEY secret-val bash
  assert_success
  assert_output "export MY_KEY='secret-val'"
}

@test "format_key_export: fish uses set -gx" {
  run format_key_export MY_KEY secret-val fish
  assert_success
  assert_output "set -gx MY_KEY 'secret-val'"
}

@test "format_key_export: POSIX escapes embedded single quotes (round-trips)" {
  run format_key_export MY_KEY "ab'c'd" bash
  assert_success
  assert_output "export MY_KEY='ab'\''c'\''d'"
  # The emitted line must eval back to the original key.
  eval "$output"
  [ "$MY_KEY" = "ab'c'd" ]
}

@test "format_key_export: fish escapes embedded single quotes" {
  run format_key_export MY_KEY "ab'cd" fish
  assert_success
  assert_output "set -gx MY_KEY 'ab\\'cd'"
}

# --- persist_key_to_rc -----------------------------------------------------

@test "persist_key_to_rc: appends an export and prints the rc path" {
  HOME="$TEST_DIR" SHELL=/bin/bash run persist_key_to_rc OPENAI_API_KEY sk-xyz
  assert_success
  assert_output "${TEST_DIR}/.bashrc"
  run grep -F "export OPENAI_API_KEY='sk-xyz'" "${TEST_DIR}/.bashrc"
  assert_success
}

# --- store_api_key ---------------------------------------------------------

write_security_stub() {
  cat >"${STUB_BIN}/security" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SECURITY_LOG"
exit 0
EOF
  chmod +x "${STUB_BIN}/security"
}

@test "store_api_key: writes to the keychain under the given service" {
  write_security_stub
  PATH="${STUB_BIN}:$PATH" run store_api_key anthropic-api-key sk-secret
  assert_success
  run cat "$SECURITY_LOG"
  assert_output --partial "add-generic-password"
  assert_output --partial "-s anthropic-api-key"
  assert_output --partial "-w sk-secret"
}

@test "store_api_key: fails when no secret-store backend exists" {
  PATH="$STUB_BIN" run store_api_key anthropic-api-key sk-secret
  assert_failure
}
