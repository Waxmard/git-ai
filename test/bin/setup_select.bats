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
