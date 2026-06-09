#!/usr/bin/env bats
load '../helpers/common'

setup() {
  load_bats_libs
  TEST_REPO="$(make_test_repo)"
  cd "$TEST_REPO"
  source "${REPO_ROOT}/lib/ai-common.sh"
  source "${REPO_ROOT}/bin/git-ai"
  export XDG_CONFIG_HOME="$(mktemp -d)"
  mkdir -p "${XDG_CONFIG_HOME}/git-ai"
  CONF="${XDG_CONFIG_HOME}/git-ai/options.conf"
}

teardown() {
  cd /tmp
  rm -rf "$TEST_REPO" "$XDG_CONFIG_HOME"
  unset XDG_CONFIG_HOME
}

# --- _setup_select (numbered fallback) ---

_select() { # CHOICE DATA  -> runs _setup_select with numbered fallback, feeding CHOICE
  GIT_AI_NO_FZF=1 bash -c '
    source "'"${REPO_ROOT}"'/lib/ai-common.sh"
    source "'"${REPO_ROOT}"'/bin/git-ai"
    printf "%s\n" "$1" | _setup_select "pick> " "$2"
  ' _ "$1" "$2"
}

@test "_setup_select: numbered fallback returns the chosen value" {
  run _select 2 $'add\tAdd\nremove\tRemove\ndone\tDone'
  assert_success
  assert_line "remove"
}

@test "_setup_select: out-of-range choice returns non-zero" {
  run _select 9 $'add\tAdd\ndone\tDone'
  assert_failure
}

@test "_setup_select: empty data returns non-zero" {
  run _select 1 ""
  assert_failure
}

# --- _setup_print_summary (models shown / empty flagged) ---

@test "_setup_print_summary: pinned models are listed, empty sections flagged" {
  cat >"$CONF" <<'EOF'
[claude-code]

[vertex-gemini]
gemini-3.5-flash
gemini-3.1-pro-preview
EOF
  run _setup_print_summary "$CONF"
  assert_success
  assert_output --partial "Vertex AI (Gemini) — gemini-3.5-flash, gemini-3.1-pro-preview"
  assert_output --partial "Claude Code — no models pinned"
}

@test "_setup_print_summary: vertex project + account shown in the header" {
  cat >"$CONF" <<'EOF'
[vertex]
projects = proj-a, proj-b

[vertex-gemini]
account = me@example.com
gemini-3.5-flash
EOF
  run _setup_print_summary "$CONF"
  assert_success
  assert_output --partial "(projects: proj-a, proj-b)"
  assert_output --partial "[account: me@example.com]"
}

@test "_setup_print_summary: single per-section vertex project shown" {
  cat >"$CONF" <<'EOF'
[vertex-anthropic]
project = solo-proj
claude-sonnet-4
EOF
  run _setup_print_summary "$CONF"
  assert_success
  assert_output --partial "(project: solo-proj)"
}

# --- _setup_existing_models (additive change-models support) ---

@test "_setup_existing_models: lists pinned models, folding @profiles to base" {
  cat >"$CONF" <<'EOF'
[vertex]
projects = a, b

[vertex-gemini]
gemini-3.5-flash
EOF
  run _setup_existing_models vertex-gemini
  assert_success
  assert_line "gemini-3.5-flash"
  # The two project profiles must collapse to a single base entry.
  [ "$(grep -c '^gemini-3.5-flash$' <<<"$output")" -eq 1 ]
}

# --- _setup_pick_projects (vertex project selection, free-text fallback) ---

@test "_setup_pick_projects: free-text fallback splits a comma list" {
  local stub; stub="$(mktemp -d)"
  printf '#!/bin/sh\nexit 1\n' >"${stub}/gcloud"  # no project list → free-text path
  chmod +x "${stub}/gcloud"
  run bash -c '
    export PATH="'"${stub}"':$PATH"
    source "'"${REPO_ROOT}"'/lib/ai-common.sh"
    source "'"${REPO_ROOT}"'/bin/git-ai"
    printf "proj-a, proj-b\n" | GIT_AI_NO_FZF=1 _setup_pick_projects
  '
  rm -rf "$stub"
  assert_success
  assert_line "proj-a"
  assert_line "proj-b"
}
