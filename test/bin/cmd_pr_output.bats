#!/usr/bin/env bats
load '../helpers/common'

setup() {
  load_bats_libs
  TEST_REPO="$(make_test_repo)"
  cd "$TEST_REPO"
  export REPO_ROOT
}

teardown() {
  cd /tmp
  rm -rf "$TEST_REPO"
}

run_render_pr_output() {
  local existing="$1"
  local output="$2"
  local is_tty="$3"

  STDOUT_FILE="$(mktemp)"
  STDERR_FILE="$(mktemp)"

  EXISTING="$existing" OUTPUT="$output" IS_TTY="$is_tty" \
    bash -lc '
      source "$REPO_ROOT/lib/ai-common.sh"
      source "$REPO_ROOT/bin/git-ai"
      render_pr_output "$EXISTING" "$OUTPUT" "$IS_TTY"
    ' >"$STDOUT_FILE" 2>"$STDERR_FILE"
  STATUS="$?"
}

@test "render_pr_output: identical cached PR in tty mode prints notice and PR text" {
  run_render_pr_output $'feat: title\n\n### Features\n- same' $'feat: title\n\n### Features\n- same' "true"

  [ "$STATUS" -eq 0 ]
  run cat "$STDOUT_FILE"
  assert_success
  assert_output $'feat: title\n\n### Features\n- same'
  run cat "$STDERR_FILE"
  assert_success
  assert_output "git-ai: regenerated PR is unchanged; no diff changes to show"
}

@test "render_pr_output: identical cached PR outside tty prints only PR text" {
  run_render_pr_output $'feat: title\n\n### Features\n- same' $'feat: title\n\n### Features\n- same' "false"

  [ "$STATUS" -eq 0 ]
  run cat "$STDOUT_FILE"
  assert_success
  assert_output $'feat: title\n\n### Features\n- same'
  run cat "$STDERR_FILE"
  assert_success
  assert_output ""
}

@test "render_pr_output: uncached PR in tty mode prints only PR text" {
  run_render_pr_output "" $'feat: title\n\n### Features\n- generated' "true"

  [ "$STATUS" -eq 0 ]
  run cat "$STDOUT_FILE"
  assert_success
  assert_output $'feat: title\n\n### Features\n- generated'
  run cat "$STDERR_FILE"
  assert_success
  assert_output ""
}

@test "render_pr_output: changed cached PR in tty mode prints visible line diff" {
  run_render_pr_output $'refactor: title\n\n### Refactors\n- existing bullet' $'refactor: title\n\n### Refactors\n- existing bullet\n- new bullet' "true"

  [ "$STATUS" -eq 0 ]
  run cat "$STDOUT_FILE"
  assert_success
  assert_output --partial "@@ -1,4 +1,5 @@"
  assert_output --partial $'\e[32m+ - new bullet\e[m'
  refute_output --partial "diff --git"
  refute_output --partial "index "
  refute_output --partial "--- "
  refute_output --partial "+++ "
  run cat "$STDERR_FILE"
  assert_success
  assert_output ""
}

@test "render_pr_output: changed line shows '~' prefix with new content on same line" {
  run_render_pr_output $'feat: title\n- old bullet' $'feat: title\n- new bullet' "true"

  [ "$STATUS" -eq 0 ]
  run cat "$STDOUT_FILE"
  assert_success
  assert_output --partial $'\e[32m~ - new bullet\e[m'
  refute_output --partial "+- (changed)"
  refute_output --partial "- old bullet"
}

@test "render_pr_output: added line shows '+' prefix and content on same line" {
  run_render_pr_output $'feat: a\n- one' $'feat: a\n- one\n- two' "true"

  [ "$STATUS" -eq 0 ]
  run cat "$STDOUT_FILE"
  assert_success
  assert_output --partial $'\e[32m+ - two\e[m'
  refute_output --partial "+- two"
}

@test "render_pr_output: removed line shows '-' prefix with red color" {
  run_render_pr_output $'feat: a\n- one\n- two' $'feat: a\n- one' "true"

  [ "$STATUS" -eq 0 ]
  run cat "$STDOUT_FILE"
  assert_success
  assert_output --partial $'\e[31m- - two\e[m'
}

@test "render_pr_output: context lines keep two-space prefix" {
  run_render_pr_output $'feat: a\n- one' $'feat: a\n- one\n- two' "true"

  [ "$STATUS" -eq 0 ]
  run cat "$STDOUT_FILE"
  assert_success
  assert_output --partial $'\n  feat: a\n'
  assert_output --partial $'\n  - one\n'
}
