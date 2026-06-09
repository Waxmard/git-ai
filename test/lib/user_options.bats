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

[vertex-gemini]
EOF
  run parse_user_options
  assert_success
  assert_line "claude-code:claude-sonnet-4-6"
  refute_output --partial "vertex-gemini:"
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

@test "parse_user_options: skips key=value config lines (not models)" {
  cat >"$CONF" <<'EOF'
[vertex-anthropic]
project = acme-prod
account = me@acme.com
claude-sonnet-4-6
EOF
  run parse_user_options
  assert_success
  assert_line "vertex-anthropic:claude-sonnet-4-6"
  refute_output --partial "project"
  refute_output --partial "account"
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
  refute_output --partial "vertex-gemini:"
  refute_output --partial "vertex-anthropic:"
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

@test "list_options: missing config lists live-discovered models" {
  rm -f "$CONF"
  # No static catalog anymore: with no config, list_options draws from model
  # discovery. Block the network and seed two providers' caches so only those
  # appear; providers with nothing discoverable contribute no rows.
  local stub
  stub="$(mktemp -d)"
  local c
  for c in curl security secret-tool pass kwallet-query gcloud; do
    printf '#!/bin/sh\nexit 1\n' >"${stub}/${c}"
    chmod +x "${stub}/${c}"
  done
  PATH="${stub}:${PATH}" \
    mkdir -p "${TEST_XDG}/git-ai/models-cache"
  printf 'claude-sonnet-4-6\n' >"${TEST_XDG}/git-ai/models-cache/claude-code.list"
  printf 'gpt-5.4-mini\n' >"${TEST_XDG}/git-ai/models-cache/codex.list"

  PATH="${stub}:${PATH}" run list_options commit
  assert_success
  assert_output --partial "claude-code:claude-sonnet-4-6|"
  assert_output --partial "codex:gpt-5.4-mini|"
  refute_output --partial "vertex-gemini:"
  rm -rf "$stub"
}

@test "list_options: present config is authoritative — empty sections hide, no discovery flood" {
  # Regression: a present options.conf whose sections pin no models must NOT fall
  # back to live discovery (which flooded the picker with every model). An empty
  # [vertex-gemini] hides that provider even though discovery could list it.
  cat >"$CONF" <<'EOF'
[vertex-gemini]

[claude-code]
claude-sonnet-4-6
EOF
  mkdir -p "${TEST_XDG}/git-ai/models-cache"
  printf 'gemini-3.5-flash\ngemini-3.1-pro-preview\n' >"${TEST_XDG}/git-ai/models-cache/vertex-gemini.list"

  run list_options commit
  assert_success
  assert_output --partial "claude-code:claude-sonnet-4-6|"
  refute_output --partial "vertex-gemini:"      # empty section hidden
  refute_output --partial "gemini-3.5-flash"    # discovery NOT consulted
}

# --- resolve_model passes any model id through (no catalog gate) ---

@test "resolve_model: accepts an arbitrary model id" {
  run resolve_model commit claude-code "claude-sonnet-5-0-preview"
  assert_success
  assert_output "claude-sonnet-5-0-preview"
}

@test "resolve_model: profile-qualified provider passes the model through" {
  run resolve_model commit "vertex-gemini@proj-01" "gemini-3.5-flash"
  assert_success
  assert_output "gemini-3.5-flash"
}

# --- vertex_config_value ---

@test "vertex_config_value: reads project/account/region for the section" {
  cat >"$CONF" <<'EOF'
[vertex-anthropic]
project = acme-prod
region  = us-east5
account = me@acme.com
claude-sonnet-4-6

[vertex-gemini]
project = other-proj
EOF
  run vertex_config_value vertex-anthropic project
  assert_success
  assert_output "acme-prod"

  run vertex_config_value vertex-anthropic region
  assert_output "us-east5"

  run vertex_config_value vertex-anthropic account
  assert_output "me@acme.com"

  # Section isolation: vertex-gemini has its own project.
  run vertex_config_value vertex-gemini project
  assert_output "other-proj"
}

@test "vertex_config_value: expands a leading ~/ to \$HOME" {
  cat >"$CONF" <<'EOF'
[vertex-gemini]
credentials = ~/keys/sa.json
EOF
  run vertex_config_value vertex-gemini credentials
  assert_success
  assert_output "${HOME}/keys/sa.json"
}

@test "vertex_config_value: profile sections are addressed by base@profile" {
  cat >"$CONF" <<'EOF'
[vertex-anthropic@acme]
project = acme-prod
account = me@acme.com
claude-sonnet-4-6

[vertex-anthropic@sandbox]
project = acme-sandbox
account = me@acme.com
claude-sonnet-4-6
EOF
  run vertex_config_value "vertex-anthropic@acme" project
  assert_output "acme-prod"

  run vertex_config_value "vertex-anthropic@sandbox" project
  assert_output "acme-sandbox"

  # Same account across both profiles.
  run vertex_config_value "vertex-anthropic@sandbox" account
  assert_output "me@acme.com"
}

@test "parse_user_options: profile sections emit base@profile:model entries" {
  cat >"$CONF" <<'EOF'
[vertex-anthropic@acme]
project = acme-prod
claude-sonnet-4-6

[vertex-anthropic@sandbox]
claude-sonnet-4-6
EOF
  run parse_user_options
  assert_success
  assert_line "vertex-anthropic@acme:claude-sonnet-4-6"
  assert_line "vertex-anthropic@sandbox:claude-sonnet-4-6"
  refute_output --partial "project"
}

@test "list_options: profile sections become distinct labelled picker entries" {
  cat >"$CONF" <<'EOF'
[vertex-anthropic@acme]
claude-sonnet-4-6

[vertex-anthropic@sandbox]
claude-sonnet-4-6
EOF
  run list_options commit
  assert_success
  assert_output --partial "vertex-anthropic@acme:claude-sonnet-4-6|claude-sonnet-4-6 · Vertex AI [acme]"
  assert_output --partial "vertex-anthropic@sandbox:claude-sonnet-4-6|claude-sonnet-4-6 · Vertex AI [sandbox]"
}

# --- shared [vertex] projects expansion ---

@test "parse_user_options: [vertex] projects expand base sections into profiles" {
  cat >"$CONF" <<'EOF'
[vertex]
account  = me@acme.com
projects = sierra-data-den, the-file-system

[vertex-gemini]
gemini-3.5-flash

[vertex-anthropic]
claude-sonnet-4-6
EOF
  run parse_user_options
  assert_success
  assert_line "vertex-gemini@sierra-data-den:gemini-3.5-flash"
  assert_line "vertex-gemini@the-file-system:gemini-3.5-flash"
  assert_line "vertex-anthropic@sierra-data-den:claude-sonnet-4-6"
  assert_line "vertex-anthropic@the-file-system:claude-sonnet-4-6"
  # The bare base sections are not emitted when projects expand them.
  refute_line "vertex-gemini:gemini-3.5-flash"
  refute_line "vertex-anthropic:claude-sonnet-4-6"
}

@test "parse_user_options: explicit profile section overrides/coexists, no dup" {
  cat >"$CONF" <<'EOF'
[vertex]
projects = sierra-data-den

[vertex-gemini]
gemini-3.5-flash

[vertex-gemini@sierra-data-den]
gemini-3.5-flash
gemini-3.1-pro-preview
EOF
  run parse_user_options
  assert_success
  # gemini-3.5-flash appears once despite both sections naming it.
  assert_equal "$(parse_user_options | grep -c 'vertex-gemini@sierra-data-den:gemini-3.5-flash')" "1"
  assert_line "vertex-gemini@sierra-data-den:gemini-3.1-pro-preview"
}

@test "list_options: expanded projects produce labelled picker entries" {
  cat >"$CONF" <<'EOF'
[vertex]
projects = sierra-data-den, the-file-system

[vertex-gemini]
gemini-3.5-flash
EOF
  run list_options commit
  assert_success
  assert_output --partial "vertex-gemini@sierra-data-den:gemini-3.5-flash|gemini-3.5-flash · Vertex AI [sierra-data-den]"
  assert_output --partial "vertex-gemini@the-file-system:gemini-3.5-flash|gemini-3.5-flash · Vertex AI [the-file-system]"
}

# --- vertex_resolve layered lookup ---

@test "vertex_resolve: inherits account from shared [vertex], project from name" {
  cat >"$CONF" <<'EOF'
[vertex]
account  = me@acme.com
region   = us-east5
projects = sierra-data-den, the-file-system

[vertex-anthropic]
claude-sonnet-4-6
EOF
  run vertex_resolve "vertex-anthropic@the-file-system" account
  assert_output "me@acme.com"

  run vertex_resolve "vertex-anthropic@the-file-system" region
  assert_output "us-east5"

  # No project= anywhere → profile name is the project.
  run vertex_resolve "vertex-anthropic@the-file-system" project
  assert_output "the-file-system"
}

@test "vertex_resolve: explicit profile section wins over shared defaults" {
  cat >"$CONF" <<'EOF'
[vertex]
account = shared@acme.com

[vertex-anthropic@special]
account = special@acme.com
project = real-project-id
claude-sonnet-4-6
EOF
  run vertex_resolve "vertex-anthropic@special" account
  assert_output "special@acme.com"

  # Explicit project= overrides the profile-name default.
  run vertex_resolve "vertex-anthropic@special" project
  assert_output "real-project-id"
}

@test "vertex_config_value: missing key or file yields empty output" {
  cat >"$CONF" <<'EOF'
[vertex-gemini]
project = p
EOF
  run vertex_config_value vertex-gemini account
  assert_success
  assert_output ""

  rm -f "$CONF"
  run vertex_config_value vertex-gemini project
  assert_success
  assert_output ""
}
