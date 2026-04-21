#!/usr/bin/env bats
load '../helpers/common'

setup() {
  load_bats_libs
  TEST_REPO="$(make_test_repo)"
  cd "$TEST_REPO"
  source "${REPO_ROOT}/lib/ai-common.sh"

  # Point XDG_CONFIG_HOME at a fresh temp dir so options.conf lookups don't
  # pick up the developer's real config.
  TEST_XDG="$(mktemp -d)"
  export XDG_CONFIG_HOME="$TEST_XDG"
  mkdir -p "${TEST_XDG}/git-ai"
  CONF="${TEST_XDG}/git-ai/options.conf"
}

teardown() {
  cd /tmp
  rm -rf "$TEST_REPO" "$TEST_XDG"
  unset XDG_CONFIG_HOME
}

# --- parse_user_options ---

@test "parse_user_options: missing file produces no output" {
  rm -f "$CONF"
  run parse_user_options
  assert_success
  assert_output ""
}

@test "parse_user_options: emits provider:model lines" {
  cat >"$CONF" <<'EOF'
[claude-code]
claude-sonnet-4-6
claude-opus-4-6

[codex]
gpt-5.4-mini
EOF
  run parse_user_options
  assert_success
  assert_line "claude-code:claude-sonnet-4-6"
  assert_line "claude-code:claude-opus-4-6"
  assert_line "codex:gpt-5.4-mini"
}

@test "parse_user_options: empty section emits nothing for that provider" {
  cat >"$CONF" <<'EOF'
[claude-code]
claude-sonnet-4-6

[vertex]
EOF
  run parse_user_options
  assert_success
  assert_line "claude-code:claude-sonnet-4-6"
  refute_output --partial "vertex:"
}

@test "parse_user_options: unknown provider headers are silently ignored" {
  cat >"$CONF" <<'EOF'
[bogusprovider]
some-model

[claude-code]
claude-opus-4-6
EOF
  run parse_user_options
  assert_success
  refute_output --partial "bogusprovider:"
  refute_output --partial "some-model"
  assert_line "claude-code:claude-opus-4-6"
}

@test "parse_user_options: skips comments and blank lines" {
  cat >"$CONF" <<'EOF'
# top comment
[claude-code]
# inline comment
claude-sonnet-4-6   # trailing comment

claude-opus-4-6
EOF
  run parse_user_options
  assert_success
  assert_line "claude-code:claude-sonnet-4-6"
  assert_line "claude-code:claude-opus-4-6"
}

@test "parse_user_options: 'last' header is not a valid provider section" {
  cat >"$CONF" <<'EOF'
[last]
anything
EOF
  run parse_user_options
  assert_success
  assert_output ""
}

# --- list_options uses the config ---

@test "list_options: config filters the output" {
  cat >"$CONF" <<'EOF'
[claude-code]
claude-sonnet-4-6

[codex]
gpt-5.4-mini
EOF
  run list_options commit
  assert_success
  assert_output --partial "claude-code:claude-sonnet-4-6|"
  assert_output --partial "codex:gpt-5.4-mini|"
  refute_output --partial "vertex:"
  refute_output --partial "anthropic-api:"
  refute_output --partial "gemini-api:"
  refute_output --partial "openai-api:"
}

@test "list_options: custom model IDs in config appear in output" {
  cat >"$CONF" <<'EOF'
[claude-code]
claude-sonnet-5-0-preview
EOF
  run list_options commit
  assert_success
  assert_output --partial "claude-code:claude-sonnet-5-0-preview|claude-sonnet-5-0-preview · Claude Code"
}

@test "list_options: missing config falls back to full catalog" {
  rm -f "$CONF"
  run list_options commit
  assert_success
  assert_output --partial "vertex:"
  assert_output --partial "claude-code:"
  assert_output --partial "codex:"
}

# --- resolve_model accepts custom IDs from config ---

@test "resolve_model: accepts custom model ID declared in config" {
  cat >"$CONF" <<'EOF'
[claude-code]
claude-sonnet-5-0-preview
EOF
  run resolve_model commit claude-code "claude-sonnet-5-0-preview"
  assert_success
  assert_output "claude-sonnet-5-0-preview"
}

@test "resolve_model: still rejects a model absent from catalog and config" {
  cat >"$CONF" <<'EOF'
[claude-code]
claude-sonnet-4-6
EOF
  run resolve_model commit claude-code "claude-sonnet-999-0-fake"
  assert_failure
}
