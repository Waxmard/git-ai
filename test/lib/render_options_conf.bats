#!/usr/bin/env bats
load '../helpers/common'

setup() {
  load_bats_libs
  TEST_DIR="$(mktemp -d)"
  export XDG_CONFIG_HOME="$TEST_DIR"
  source "${REPO_ROOT}/lib/ai-common.sh"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "render_options_conf: groups models under one header per provider" {
  run render_options_conf <<'EOF'
claude-code:claude-sonnet-4-6
claude-code:claude-opus-4-6
gemini-api:gemini-3.1-pro-preview
EOF
  assert_success
  assert_line '[claude-code]'
  assert_line 'claude-sonnet-4-6'
  assert_line 'claude-opus-4-6'
  assert_line '[gemini-api]'
  assert_line 'gemini-3.1-pro-preview'
  # Exactly one header per provider.
  assert_equal "$(printf '%s\n' "$output" | grep -c '^\[claude-code\]$')" "1"
}

@test "render_options_conf: dedups repeated models within a provider" {
  run render_options_conf <<'EOF'
claude-code:claude-sonnet-4-6
claude-code:claude-sonnet-4-6
EOF
  assert_success
  assert_equal "$(printf '%s\n' "$output" | grep -c '^claude-sonnet-4-6$')" "1"
}

@test "render_options_conf: a provider with no model emits an empty header" {
  run render_options_conf <<'EOF'
openai-api:
EOF
  assert_success
  assert_line '[openai-api]'
  refute_line --partial 'gpt'
}

@test "render_options_conf: preserves first-seen provider order" {
  run render_options_conf <<'EOF'
gemini-api:gemini-3.1-pro-preview
claude-code:claude-sonnet-4-6
EOF
  assert_success
  local gem_idx cc_idx
  gem_idx=$(printf '%s\n' "$output" | grep -n '^\[gemini-api\]$' | cut -d: -f1)
  cc_idx=$(printf '%s\n' "$output" | grep -n '^\[claude-code\]$' | cut -d: -f1)
  [ "$gem_idx" -lt "$cc_idx" ]
}

@test "render_options_conf: output round-trips through parse_user_options" {
  mkdir -p "${XDG_CONFIG_HOME}/git-ai"
  render_options_conf >"${XDG_CONFIG_HOME}/git-ai/options.conf" <<'EOF'
claude-code:claude-sonnet-4-6
claude-code:claude-opus-4-6
gemini-api:gemini-3.1-pro-preview
EOF
  run parse_user_options
  assert_success
  assert_line 'claude-code:claude-sonnet-4-6'
  assert_line 'claude-code:claude-opus-4-6'
  assert_line 'gemini-api:gemini-3.1-pro-preview'
}
