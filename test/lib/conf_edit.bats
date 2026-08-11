#!/usr/bin/env bats
load '../helpers/common'

setup() {
  load_bats_libs
  TEST_DIR="$(mktemp -d)"
  export XDG_CONFIG_HOME="$TEST_DIR"
  source "${REPO_ROOT}/lib/ai-common.sh"
  FIXTURE="${TEST_DIR}/options.conf"
  cat >"$FIXTURE" <<'EOF'
# my hand-written config

[claude-code]
claude-sonnet-4-6

[codex]
gpt-5.4-mini
gpt-5.5

[vertex]
account  = me@acme.com
projects = alpha, beta

[vertex-gemini]
gemini-3.5-flash
EOF
}

teardown() {
  rm -rf "$TEST_DIR"
}

# --- conf_section_providers ------------------------------------------------

@test "conf_section_providers: lists provider sections, skips shared [vertex]" {
  run conf_section_providers <"$FIXTURE"
  assert_success
  assert_line 'claude-code'
  assert_line 'codex'
  assert_line 'vertex-gemini'
  refute_line 'vertex'
}

# --- conf_remove_section ---------------------------------------------------

@test "conf_remove_section: drops only the target section" {
  run conf_remove_section codex <"$FIXTURE"
  assert_success
  refute_line '[codex]'
  refute_line 'gpt-5.4-mini'
  # Everything else preserved.
  assert_line '[claude-code]'
  assert_line 'account  = me@acme.com'
  assert_line '[vertex-gemini]'
}

# --- conf_add_section ------------------------------------------------------

@test "conf_add_section: appends a new provider, preserves the rest" {
  run conf_add_section gemini-api gemini-3.1-pro-preview <"$FIXTURE"
  assert_success
  assert_line '[gemini-api]'
  assert_line 'gemini-3.1-pro-preview'
  # Original content intact.
  assert_line '[claude-code]'
  assert_line 'projects = alpha, beta'
}

@test "conf_add_section: result round-trips through parse_user_options" {
  mkdir -p "${XDG_CONFIG_HOME}/git-ai"
  conf_add_section gemini-api gemini-3.1-pro-preview <"$FIXTURE" \
    >"${XDG_CONFIG_HOME}/git-ai/options.conf"
  run parse_user_options
  assert_success
  assert_line 'gemini-api:gemini-3.1-pro-preview'
  assert_line 'claude-code:claude-sonnet-4-6'
}

# --- conf_set_section_models ----------------------------------------------

@test "conf_set_section_models: replaces models, keeps the rest of the section" {
  run conf_set_section_models codex gpt-5.4 <"$FIXTURE"
  assert_success
  assert_line 'gpt-5.4'
  refute_line 'gpt-5.4-mini'
  refute_line 'gpt-5.5'
  assert_line '[codex]'
}

@test "conf_set_section_models: PRESERVES vertex account/projects settings" {
  run conf_set_section_models vertex-gemini gemini-3.1-pro-preview <"$FIXTURE"
  assert_success
  assert_line 'gemini-3.1-pro-preview'
  refute_line 'gemini-3.5-flash'
  # The shared [vertex] block and its settings must survive untouched.
  assert_line 'account  = me@acme.com'
  assert_line 'projects = alpha, beta'
  assert_line '[vertex]'
}

@test "conf_set_section_models: untouched sections are byte-preserved" {
  conf_set_section_models codex gpt-5.4 <"$FIXTURE" >"${TEST_DIR}/out.conf"
  # claude-code + vertex blocks identical to the original.
  run grep -A1 '^\[claude-code\]$' "${TEST_DIR}/out.conf"
  assert_output --partial 'claude-sonnet-4-6'
}

# --- conf_set_section_setting ----------------------------------------------

@test "conf_set_section_setting: inserts a new setting, keeps models" {
  run conf_set_section_setting vertex-gemini project my-proj <"$FIXTURE"
  assert_success
  assert_line 'project = my-proj'
  assert_line 'gemini-3.5-flash'
  assert_line '[vertex-gemini]'
}

@test "conf_set_section_setting: updates an existing key in place (no dup)" {
  printf '[vertex-gemini]\nregion = us-central1\ngemini-3.5-flash\n' >"${TEST_DIR}/v.conf"
  run conf_set_section_setting vertex-gemini region us-east5 <"${TEST_DIR}/v.conf"
  assert_success
  assert_line 'region = us-east5'
  refute_line 'region = us-central1'
  assert_equal "$(printf '%s\n' "$output" | grep -c '^region')" "1"
}

@test "conf_set_section_setting: appends a section when the provider is absent" {
  run conf_set_section_setting vertex-anthropic project acme <"$FIXTURE"
  assert_success
  assert_line '[vertex-anthropic]'
  assert_line 'project = acme'
}

@test "conf_set_section_setting: leaves the shared [vertex] block untouched" {
  run conf_set_section_setting vertex-gemini region us-east5 <"$FIXTURE"
  assert_success
  # Setting goes in [vertex-gemini], not the shared [vertex] block.
  assert_line 'account  = me@acme.com'
  assert_line 'projects = alpha, beta'
}

# --- conf_remove_section_setting -------------------------------------------

@test "conf_remove_section_setting: drops the key, keeps the section's other lines" {
  run conf_remove_section_setting vertex projects <"$FIXTURE"
  assert_success
  refute_line 'projects = alpha, beta'
  assert_line '[vertex]'
  assert_line 'account  = me@acme.com'
}

@test "conf_remove_section_setting: only touches the named section" {
  printf '[vertex]\nprojects = a\n\n[vertex-gemini]\nprojects = b\n' >"${TEST_DIR}/v.conf"
  run conf_remove_section_setting vertex-gemini projects <"${TEST_DIR}/v.conf"
  assert_success
  assert_line 'projects = a'
  assert_equal "$(printf '%s\n' "$output" | grep -c '^projects')" "1"
}

@test "conf_remove_section_setting: absent key passes the file through" {
  run conf_remove_section_setting vertex region <"$FIXTURE"
  assert_success
  assert_line 'projects = alpha, beta'
  assert_line 'gemini-3.5-flash'
}
