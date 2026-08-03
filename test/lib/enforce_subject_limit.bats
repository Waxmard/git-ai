#!/usr/bin/env bats
load '../helpers/common'

setup() {
  load_bats_libs
  source "${REPO_ROOT}/lib/ai-common.sh"
}

# enforce_subject_limit mirrors python/git_ai/_generate.py:enforce_subject_limit.
# It reports through globals, so the assertions read them rather than $output.

@test "enforce_subject_limit: a short subject passes through untouched" {
  enforce_subject_limit "$(printf '%s\n' 'feat: add thing' '' 'Body line.')"
  assert_equal "$GIT_AI_SUBJECT_MESSAGE" "$(printf '%s\n' 'feat: add thing' '' 'Body line.')"
  assert_equal "$GIT_AI_SUBJECT_NOTE" ""
}

@test "enforce_subject_limit: trims at an 'and' boundary and notes the drop" {
  enforce_subject_limit 'feat: restructure PR body prompts around purpose sections and fix nested fence stripping'
  assert_equal "$GIT_AI_SUBJECT_MESSAGE" 'feat: restructure PR body prompts around purpose sections'
  assert_equal "$GIT_AI_SUBJECT_NOTE" 'trimmed: dropped "and fix nested fence stripping" (was 88 chars, limit 70)'
}

@test "enforce_subject_limit: keeps the longest head within the limit" {
  enforce_subject_limit 'fix: preserve the cached PR body across rebases, force-pushes, and amended commits'
  assert_equal "$GIT_AI_SUBJECT_MESSAGE" 'fix: preserve the cached PR body across rebases, force-pushes'
}

@test "enforce_subject_limit: the body survives the trim" {
  enforce_subject_limit "$(printf '%s\n' 'feat: restructure PR body prompts around purpose sections and fix nested fence stripping' '' 'Body line one.' 'Body line two.')"
  assert_equal "$GIT_AI_SUBJECT_MESSAGE" "$(printf '%s\n' 'feat: restructure PR body prompts around purpose sections' '' 'Body line one.' 'Body line two.')"
}

@test "enforce_subject_limit: no clause break leaves the subject alone and warns" {
  local subject='feat: introduce a deterministic branch fingerprint mechanism for caching'
  enforce_subject_limit "$subject"
  assert_equal "$GIT_AI_SUBJECT_MESSAGE" "$subject"
  assert_equal "$GIT_AI_SUBJECT_NOTE" 'subject is 72 chars (limit 70) - no clean clause break; shorten this line'
}

@test "enforce_subject_limit: a break yielding a stub is rejected" {
  local subject='refactor: split, then rewrite the entire wizard flow end to end for clarity'
  enforce_subject_limit "$subject"
  assert_equal "$GIT_AI_SUBJECT_MESSAGE" "$subject"
  [[ "$GIT_AI_SUBJECT_NOTE" == "subject is 75 chars"* ]]
}

@test "enforce_subject_limit: a separator inside the scope is skipped" {
  enforce_subject_limit 'refactor(setup, vertex): move project discovery into its own module and simplify the picker'
  assert_equal "$GIT_AI_SUBJECT_MESSAGE" 'refactor(setup, vertex): move project discovery into its own module'
}

@test "enforce_subject_limit: trimming is idempotent" {
  enforce_subject_limit 'feat: restructure PR body prompts around purpose sections and fix nested fence stripping'
  enforce_subject_limit "$GIT_AI_SUBJECT_MESSAGE"
  assert_equal "$GIT_AI_SUBJECT_MESSAGE" 'feat: restructure PR body prompts around purpose sections'
  assert_equal "$GIT_AI_SUBJECT_NOTE" ""
}

@test "enforce_subject_limit: a non-UTF-8 locale still counts characters" {
  LC_ALL=C enforce_subject_limit 'fix: handle the em—dash case and tidy up the whitespace scanner paths2'
  assert_equal "$GIT_AI_SUBJECT_MESSAGE" 'fix: handle the em—dash case and tidy up the whitespace scanner paths2'
  assert_equal "$GIT_AI_SUBJECT_NOTE" ""
}
