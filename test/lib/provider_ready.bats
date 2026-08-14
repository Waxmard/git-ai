#!/usr/bin/env bats
load '../helpers/common'

setup() {
  load_bats_libs
  TEST_DIR="$(mktemp -d)"
  STUB_BIN="${TEST_DIR}/bin"
  mkdir -p "$STUB_BIN"
  GCLOUD_LOG="${TEST_DIR}/gcloud.log"
  export GCLOUD_LOG
  # Isolate from the developer's real env + ~/.config so readiness is deterministic.
  unset ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY \
    GOOGLE_CLOUD_PROJECT GOOGLE_VERTEX_PROJECT
  export XDG_CONFIG_HOME="$TEST_DIR"
  source "${REPO_ROOT}/lib/ai-common.sh"
}

teardown() {
  rm -rf "$TEST_DIR"
}

write_cli_stub() {
  printf '#!/usr/bin/env bash\nexit 0\n' >"${STUB_BIN}/$1"
  chmod +x "${STUB_BIN}/$1"
}

write_adc_gcloud_stub() {
  cat >"${STUB_BIN}/gcloud" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 $2 $3" == "auth application-default print-access-token" ]]; then
  printf 'adc-token\n'; exit 0
fi
exit 1
EOF
  chmod +x "${STUB_BIN}/gcloud"
}

# --- CLI providers ---------------------------------------------------------

@test "provider_ready: claude-code fails when the CLI is absent" {
  PATH="$STUB_BIN" run provider_ready claude-code
  assert_failure
}

@test "provider_ready: claude-code succeeds when the CLI is present" {
  write_cli_stub claude
  PATH="${STUB_BIN}:$PATH" run provider_ready claude-code
  assert_success
}

@test "provider_ready: codex succeeds when the CLI is present" {
  write_cli_stub codex
  PATH="${STUB_BIN}:$PATH" run provider_ready codex
  assert_success
}

@test "provider_ready: antigravity succeeds when the CLI is present" {
  write_cli_stub agy
  PATH="${STUB_BIN}:$PATH" run provider_ready antigravity
  assert_success
}

@test "provider_ready: antigravity fails when the CLI is absent" {
  PATH="$STUB_BIN" run provider_ready antigravity
  assert_failure
  assert_output --partial "Antigravity CLI not installed"
}

# --- key-based providers ---------------------------------------------------

@test "provider_ready: anthropic-api succeeds with an env key" {
  export ANTHROPIC_API_KEY="sk-test"
  run provider_ready anthropic-api
  assert_success
}

@test "provider_ready: anthropic-api fails with no key anywhere" {
  PATH="$STUB_BIN" run provider_ready anthropic-api
  assert_failure
}

@test "provider_ready: openai-api succeeds with an env key" {
  export OPENAI_API_KEY="sk-test"
  run provider_ready openai-api
  assert_success
}

@test "provider_ready: gemini-api succeeds with an env key" {
  export GEMINI_API_KEY="g-key"
  run provider_ready gemini-api
  assert_success
}

@test "provider_ready: gemini-api fails with no key anywhere" {
  PATH="$STUB_BIN" run provider_ready gemini-api
  assert_failure
  assert_output --partial "GEMINI_API_KEY not set"
}

# --- vertex providers ------------------------------------------------------

@test "provider_ready: vertex succeeds with ADC auth and a project" {
  write_adc_gcloud_stub
  export GOOGLE_CLOUD_PROJECT="proj"
  PATH="${STUB_BIN}:$PATH" run provider_ready vertex-gemini
  assert_success
}

@test "provider_ready: vertex fails when no project is configured" {
  write_adc_gcloud_stub
  PATH="${STUB_BIN}:$PATH" run provider_ready vertex-anthropic
  assert_failure
}

@test "provider_ready: vertex succeeds with ADC and only a shared projects list" {
  write_adc_gcloud_stub
  mkdir -p "${TEST_DIR}/git-ai"
  printf '[vertex]\nprojects = proj-a, proj-b\n' >"${TEST_DIR}/git-ai/options.conf"
  PATH="${STUB_BIN}:$PATH" run provider_ready vertex
  assert_success
}

# --- unknown ---------------------------------------------------------------

@test "provider_ready: unknown provider fails" {
  run provider_ready bogus-provider
  assert_failure
}
