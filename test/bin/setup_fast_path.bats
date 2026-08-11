#!/usr/bin/env bats
load '../helpers/common'

setup() {
  load_bats_libs
  TEST_REPO="$(make_test_repo)"
  cd "$TEST_REPO"
  export XDG_CONFIG_HOME="$(mktemp -d)"
  mkdir -p "${XDG_CONFIG_HOME}/git-ai"
  CONF="${XDG_CONFIG_HOME}/git-ai/options.conf"
  # Pin a fixture data file so routine model bumps in recommended-models.conf
  # can't break these tests (ai-common.sh respects a pre-set env value).
  export GIT_AI_RECOMMENDED_MODELS_FILE="${XDG_CONFIG_HOME}/recommended-models.conf"
  printf 'anthropic = claude-rec-test\ngoogle = gemini-rec-test\nopenai = gpt-rec-test\n' \
    >"$GIT_AI_RECOMMENDED_MODELS_FILE"
}

teardown() {
  cd /tmp
  rm -rf "$TEST_REPO" "$XDG_CONFIG_HOME"
  unset XDG_CONFIG_HOME GIT_AI_RECOMMENDED_MODELS_FILE
}

# _fast CONF PROVIDER...  -> sources the CLI and runs _setup_fast_path with
# stdin closed: the landing overview's action prompt reads EOF, which selects
# the default Done — the same as a user pressing Enter. GIT_AI_NO_FZF forces
# the numbered fallback; without it fzf would open its UI on /dev/tty and hang
# the test run.
_fast() {
  local conf="$1"
  shift
  GIT_AI_NO_FZF=1 bash -c '
    source "'"${REPO_ROOT}"'/lib/ai-common.sh"
    source "'"${REPO_ROOT}"'/bin/git-ai"
    conf="$1"; shift
    _setup_fast_path "$conf" "$@"
  ' _ "$conf" "$@" </dev/null
}

@test "_setup_fast_path: enables ready providers with recommended models, no questions" {
  run _fast "$CONF" claude-code gemini-api
  assert_success
  assert_output --partial "enabling them with recommended models"
  assert_output --partial "claude-rec-test"
  assert_output --partial "gemini-rec-test"

  run cat "$CONF"
  assert_line "[claude-code]"
  assert_line "claude-rec-test"
  assert_line "[gemini-api]"
  assert_line "gemini-rec-test"
}

@test "_setup_fast_path: lands on the config overview" {
  run _fast "$CONF" claude-code
  assert_success
  assert_output --partial "Configured providers:"
  assert_output --partial "Claude Code — claude-rec-test"
}

@test "_setup_fast_path: vertex expands to both internal sections, one user-facing row" {
  # No project resolvable anywhere: the base sections are the only place to pin,
  # and vertex takes its project from the environment at run time.
  run env -u GOOGLE_VERTEX_PROJECT -u GOOGLE_CLOUD_PROJECT bash -c '
    source "'"${REPO_ROOT}"'/lib/ai-common.sh"
    source "'"${REPO_ROOT}"'/bin/git-ai"
    GIT_AI_NO_FZF=1 _setup_fast_path "'"$CONF"'" vertex </dev/null
  '
  assert_success
  # One unified display row, never the internal split.
  assert_output --partial "Vertex AI"
  refute_output --partial "vertex-gemini"
  refute_output --partial "vertex-anthropic"

  run cat "$CONF"
  assert_line "[vertex-anthropic]"
  assert_line "claude-rec-test"
  assert_line "[vertex-gemini]"
  assert_line "gemini-rec-test"
}

@test "_setup_fast_path: reset carries prior vertex projects into per-project sections" {
  cat >"$CONF" <<'EOF'
[vertex]
projects = proj-a, proj-b
account = me@example.com

[vertex-gemini]
gemini-3.5-flash
EOF
  run _fast "$CONF" vertex
  assert_success
  run cat "$CONF"
  assert_line "[vertex-gemini@proj-a]"
  assert_line "[vertex-gemini@proj-b]"
  assert_line "[vertex-anthropic@proj-a]"
  assert_line "[vertex-anthropic@proj-b]"
  assert_line "account = me@example.com"
  # The projects list drove the old cross product; the sections are the record now.
  refute_output --partial "projects ="
}

@test "_setup_fast_path: detected vertex project is written when nothing else resolves" {
  # The host shell may export a real GCP project — unset both env fallbacks so
  # only the stashed detection result can resolve.
  run env -u GOOGLE_VERTEX_PROJECT -u GOOGLE_CLOUD_PROJECT bash -c '
    source "'"${REPO_ROOT}"'/lib/ai-common.sh"
    source "'"${REPO_ROOT}"'/bin/git-ai"
    SETUP_VERTEX_DETECTED="detected-proj"
    GIT_AI_NO_FZF=1 _setup_fast_path "'"$CONF"'" vertex </dev/null
  '
  assert_success
  run cat "$CONF"
  assert_line "[vertex-gemini@detected-proj]"
}

@test "_setup_fast_path: env-derived vertex project is written to the config" {
  run env GOOGLE_CLOUD_PROJECT=env-proj bash -c '
    source "'"${REPO_ROOT}"'/lib/ai-common.sh"
    source "'"${REPO_ROOT}"'/bin/git-ai"
    GIT_AI_NO_FZF=1 _setup_fast_path "'"$CONF"'" vertex </dev/null
  '
  assert_success
  run cat "$CONF"
  assert_line "[vertex-anthropic@env-proj]"
}

@test "_setup_fast_path: seeds the per-repo default provider" {
  run _fast "$CONF" gemini-api claude-code
  assert_success
  source "${REPO_ROOT}/lib/ai-common.sh"
  run get_last_provider commit
  assert_output "gemini-api"
}

@test "_setup_fast_path: vertex-first seeds a concrete runnable token" {
  run env -u GOOGLE_VERTEX_PROJECT -u GOOGLE_CLOUD_PROJECT bash -c '
    source "'"${REPO_ROOT}"'/lib/ai-common.sh"
    source "'"${REPO_ROOT}"'/bin/git-ai"
    GIT_AI_NO_FZF=1 _setup_fast_path "'"$CONF"'" vertex gemini-api </dev/null
  '
  assert_success
  source "${REPO_ROOT}/lib/ai-common.sh"
  run get_last_provider commit
  assert_output "vertex-anthropic"
}

@test "_setup_fast_path: vertex default is profile-qualified when a project is known" {
  run env GOOGLE_CLOUD_PROJECT=env-proj bash -c '
    source "'"${REPO_ROOT}"'/lib/ai-common.sh"
    source "'"${REPO_ROOT}"'/bin/git-ai"
    GIT_AI_NO_FZF=1 _setup_fast_path "'"$CONF"'" vertex </dev/null
  '
  assert_success
  source "${REPO_ROOT}/lib/ai-common.sh"
  run get_last_provider commit
  assert_output "vertex-anthropic@env-proj"
}
