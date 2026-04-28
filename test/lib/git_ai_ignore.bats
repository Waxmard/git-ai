#!/usr/bin/env bats
load '../helpers/common'

setup() {
  load_bats_libs
  TEST_REPO="$(make_test_repo)"
  cd "$TEST_REPO"
  source "${REPO_ROOT}/lib/ai-common.sh"
}

teardown() {
  cd /tmp
  rm -rf "$TEST_REPO"
}

# --- load_git_ai_ignore ---

@test "load_git_ai_ignore: returns built-in defaults when no file present" {
  run load_git_ai_ignore "$TEST_REPO"
  assert_success
  assert_line "package-lock.json"
  assert_line "yarn.lock"
  assert_line "Cargo.lock"
  assert_line "uv.lock"
}

@test "load_git_ai_ignore: appends additions, ignores comments and blank lines" {
  cat >"${TEST_REPO}/.git-ai-ignore" <<'EOF'
# header comment

build/dist.js
   # indented comment
foo/bar.lock
EOF
  run load_git_ai_ignore "$TEST_REPO"
  assert_success
  assert_line "build/dist.js"
  assert_line "foo/bar.lock"
  refute_line "# header comment"
}

@test "load_git_ai_ignore: !pattern removes a built-in default" {
  cat >"${TEST_REPO}/.git-ai-ignore" <<'EOF'
!package-lock.json
EOF
  run load_git_ai_ignore "$TEST_REPO"
  assert_success
  refute_line "package-lock.json"
  assert_line "yarn.lock"
}

@test "load_git_ai_ignore: dedupes repeated patterns" {
  cat >"${TEST_REPO}/.git-ai-ignore" <<'EOF'
foo.lock
foo.lock
package-lock.json
EOF
  run load_git_ai_ignore "$TEST_REPO"
  assert_success
  local count
  count=$(printf '%s\n' "$output" | grep -c '^foo\.lock$')
  [[ "$count" == "1" ]]
}

# --- build_pathspec_excludes ---

@test "build_pathspec_excludes: emits nothing when no patterns" {
  run build_pathspec_excludes
  assert_success
  assert_output ""
}

@test "build_pathspec_excludes: emits -- . :(exclude,glob)**/X for each pattern" {
  run build_pathspec_excludes "package-lock.json" "yarn.lock"
  assert_success
  local expected
  expected="--
.
:(exclude,glob)**/package-lock.json
:(exclude,glob)**/yarn.lock"
  assert_output "$expected"
}

# --- check_diff_size_or_die ---

@test "check_diff_size_or_die: passes through when under limit" {
  GIT_AI_MAX_DIFF_BYTES=1000 run check_diff_size_or_die "small diff"
  assert_success
  assert_output ""
}

@test "check_diff_size_or_die: aborts with top-files hint when over limit" {
  local big_diff
  big_diff="diff --git a/huge.json b/huge.json
--- a/huge.json
+++ b/huge.json
@@ -0,0 +1,200 @@
"
  local i
  for ((i = 0; i < 200; i++)); do
    big_diff+=$'+'"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"$'\n'
  done

  GIT_AI_MAX_DIFF_BYTES=500 run check_diff_size_or_die "$big_diff"
  assert_failure
  assert_output --partial "exceeds limit"
  assert_output --partial "Largest changed files"
  assert_output --partial "huge.json"
  assert_output --partial ".git-ai-ignore"
}

@test "check_diff_size_or_die: GIT_AI_MAX_DIFF_BYTES=0 disables guard" {
  local big_diff="diff --git a/x b/x"$'\n'
  local i
  for ((i = 0; i < 200; i++)); do
    big_diff+=$'+'"yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy"$'\n'
  done
  GIT_AI_MAX_DIFF_BYTES=0 run check_diff_size_or_die "$big_diff"
  assert_success
}
