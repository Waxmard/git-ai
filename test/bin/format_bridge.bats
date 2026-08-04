#!/usr/bin/env bats
# The parse/wrap/subject-limit rules live only in Python now; these assert the
# shell reaches them and hands back the right bytes. Rule coverage itself is in
# test/python/ (test_commit_cli_format.py, test_subject_limit.py, ...).
load '../helpers/common'

setup() {
  load_bats_libs
  export REPO_ROOT
  NOTE_FILE="$(mktemp)"
}

teardown() {
  rm -f "$NOTE_FILE"
}

commit_format() {
  printf '%s' "$1" | "${GIT_AI_PYTHON:-python3}" \
    "${REPO_ROOT}/python/git_ai/_commit_cli.py" format --note-file "$NOTE_FILE"
}

@test "commit format bridge: unwraps fences, marker, and agent trailer" {
  run commit_format $'```\n===COMMIT===\nfeat: add the picker\n\nBody line.\n\nCo-Authored-By: A <a@b.c>\n```'
  assert_success
  assert_output $'feat: add the picker\n\nBody line.'
}

@test "commit format bridge: trims the subject and reports it in the note" {
  run commit_format 'feat: restructure PR body prompts around purpose sections and fix nested fence stripping'
  assert_success
  assert_output 'feat: restructure PR body prompts around purpose sections'
  run cat "$NOTE_FILE"
  assert_output 'trimmed: dropped "and fix nested fence stripping" (was 88 chars, limit 70)'
}

@test "commit format bridge: empty response yields empty stdout for the shell to report" {
  run commit_format $'   \n\n  '
  assert_success
  assert_output ''
}

@test "pr format bridge: slices the title/body markers" {
  run bash -c 'printf "%s" "$1" | "${GIT_AI_PYTHON:-python3}" "${REPO_ROOT}/python/git_ai/_pr_repo_cli.py" format' _ \
    $'preamble\n===TITLE===\nfeat: add it\n===BODY===\n## Summary\n\nText.'
  assert_success
  assert_output $'feat: add it\n\n## Summary\n\nText.'
}

@test "require_python: dies with a named error when the interpreter is missing" {
  run bash -lc '
    source "$REPO_ROOT/lib/ai-common.sh"
    GIT_AI_PYTHON=definitely-not-a-real-interpreter require_python
  '
  assert_failure
  assert_output --partial 'requires python3'
}
