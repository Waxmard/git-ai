#!/usr/bin/env bats
# The parse/wrap/subject-limit and .git-ai-ignore/.git-ai-instructions rules
# live only in Python now; these assert the shell reaches them and hands back
# the right bytes. Rule coverage itself is in test/python/ (test_commit_cli.py,
# test_subject_limit.py, test_ignore.py, ...).
load '../helpers/common'

setup() {
  load_bats_libs
  export REPO_ROOT
  PROMPT_FILE="$(mktemp)"
}

teardown() {
  rm -f "$PROMPT_FILE"
}

@test "commit build-prompt bridge: emits prepared input and writes prompt" {
  local repo
  repo="$(make_test_repo)"
  printf 'ready\n' >"$repo/file.txt"
  git -C "$repo" add file.txt

  run "${GIT_AI_PYTHON:-python3}" "${REPO_ROOT}/python/git_ai/_commit_cli.py" \
    build-prompt --repo "$repo" --prompt-file "$PROMPT_FILE"

  assert_success
  assert_output --partial "<changed_files>"
  assert_output --partial "+ready"
  run grep -F "===COMMIT===" "$PROMPT_FILE"
  assert_success
}

@test "require_python: dies with a named error when the interpreter is missing" {
  run bash -lc '
    source "$REPO_ROOT/lib/ai-common.sh"
    GIT_AI_PYTHON=definitely-not-a-real-interpreter require_python
  '
  assert_failure
  assert_output --partial 'requires python3'
}
