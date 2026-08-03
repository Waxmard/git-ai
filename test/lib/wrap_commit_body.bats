#!/usr/bin/env bats
load '../helpers/common'

setup() {
  load_bats_libs
  source "${REPO_ROOT}/lib/ai-common.sh"
  TEST_TMP="$(mktemp -d)"
  LONG="Replaces the flat group-bullets-by-type PR body format with purpose sections scaled to the size of the change, so a one-concern branch gets prose and a large one gets the full set of headings."
}

teardown() {
  rm -rf "$TEST_TMP"
}

# Mirrors test/python/test_wrap_commit_body.py. A temp file feeds stdin so the
# fenced-block case can contain backticks without escaping games.

# Longest body line, so a single assertion covers the whole wrap.
max_body_width() {
  awk 'NR>1 && length>m {m=length} END{print m+0}'
}

@test "wrap_commit_body: subject-only message untouched" {
  printf '%s\n' 'feat: add thing' > "$TEST_TMP/in.txt"
  run wrap_commit_body < "$TEST_TMP/in.txt"
  assert_success
  assert_output "feat: add thing"
}

@test "wrap_commit_body: wraps a long paragraph at 72" {
  printf '%s\n\n%s\n' 'feat: add thing' "$LONG" > "$TEST_TMP/in.txt"
  width=$(wrap_commit_body < "$TEST_TMP/in.txt" | max_body_width)
  [ "$width" -le 72 ]
  [ "$width" -gt 0 ]
}

@test "wrap_commit_body: never wraps the subject" {
  subject="feat: $(printf 'x%.0s' {1..100})"
  printf '%s\n\n%s\n' "$subject" 'body' > "$TEST_TMP/in.txt"
  run wrap_commit_body < "$TEST_TMP/in.txt"
  assert_success
  assert_line --index 0 "$subject"
}

@test "wrap_commit_body: idempotent" {
  printf '%s\n\n%s\n' 'feat: add thing' "$LONG" > "$TEST_TMP/in.txt"
  wrap_commit_body < "$TEST_TMP/in.txt" > "$TEST_TMP/once.txt"
  wrap_commit_body < "$TEST_TMP/once.txt" > "$TEST_TMP/twice.txt"
  run diff "$TEST_TMP/once.txt" "$TEST_TMP/twice.txt"
  assert_success
}

@test "wrap_commit_body: paragraph breaks preserved" {
  printf '%s\n\n%s\n\n%s\n' 'feat: x' 'first para' 'second para' > "$TEST_TMP/in.txt"
  expected=$(printf '%s\n\n%s\n\n%s' 'feat: x' 'first para' 'second para')
  run wrap_commit_body < "$TEST_TMP/in.txt"
  assert_success
  assert_output "$expected"
}

@test "wrap_commit_body: reflows a raggedly wrapped paragraph" {
  printf '%s\n\n%s\n%s\n%s\n%s\n' 'feat: x' 'short' 'lines that' 'the model' 'wrapped badly' > "$TEST_TMP/in.txt"
  expected=$(printf '%s\n\n%s' 'feat: x' 'short lines that the model wrapped badly')
  run wrap_commit_body < "$TEST_TMP/in.txt"
  assert_success
  assert_output "$expected"
}

@test "wrap_commit_body: list items untouched" {
  item="- $(printf 'word %.0s' {1..30})"
  item="${item% }"
  printf '%s\n\n%s\n' 'feat: x' "$item" > "$TEST_TMP/in.txt"
  expected=$(printf '%s\n\n%s' 'feat: x' "$item")
  run wrap_commit_body < "$TEST_TMP/in.txt"
  assert_success
  assert_output "$expected"
}

@test "wrap_commit_body: indented block untouched" {
  block="    $(printf 'word %.0s' {1..30})"
  block="${block% }"
  printf '%s\n\n%s\n' 'feat: x' "$block" > "$TEST_TMP/in.txt"
  expected=$(printf '%s\n\n%s' 'feat: x' "$block")
  run wrap_commit_body < "$TEST_TMP/in.txt"
  assert_success
  assert_output "$expected"
}

@test "wrap_commit_body: fenced block untouched" {
  printf '%s\n\n%s\n%s\n%s\n' 'feat: x' '```bash' 'gcloud workstations create verify-name --cluster=demo --region=example-west1' '```' > "$TEST_TMP/in.txt"
  expected=$(printf '%s\n\n%s\n%s\n%s' 'feat: x' '```bash' 'gcloud workstations create verify-name --cluster=demo --region=example-west1' '```')
  run wrap_commit_body < "$TEST_TMP/in.txt"
  assert_success
  assert_output "$expected"
}

@test "wrap_commit_body: multi-stanza fenced block untouched" {
  printf '%s\n\n%s\n%s\n\n%s\n%s\n\n%s\n%s\n' 'feat: x' '```bash' 'echo one' \
    'echo an interior stanza that carries no fence marker of its very own' 'echo three' \
    'echo done' '```' > "$TEST_TMP/in.txt"
  expected=$(cat "$TEST_TMP/in.txt")
  run wrap_commit_body < "$TEST_TMP/in.txt"
  assert_success
  assert_output "$expected"
}

@test "wrap_commit_body: nested fenced block untouched" {
  printf '%s\n\n%s\n%s\n%s\n\n%s\n%s\n\n%s\n%s\n%s\n' 'feat: x' '````markdown' '```text' 'first' \
    'line one of the interior stanza' 'line two of the interior stanza' \
    'third' '```' '````' > "$TEST_TMP/in.txt"
  expected=$(cat "$TEST_TMP/in.txt")
  run wrap_commit_body < "$TEST_TMP/in.txt"
  assert_success
  assert_output "$expected"
}

@test "wrap_commit_body: prose after a fenced block still wraps" {
  printf '%s\n\n%s\n%s\n\n%s\n%s\n\n%s\n' 'feat: x' '```' 'code a' 'code b' '```' "$LONG" > "$TEST_TMP/in.txt"
  run wrap_commit_body < "$TEST_TMP/in.txt"
  assert_success
  assert_line 'code b'
  width=$(printf '%s\n' "$output" | max_body_width)
  assert [ "$width" -le 72 ]
}

@test "wrap_commit_body: trailing trailer block untouched" {
  trailer='Reviewed-by: A Person <averylongaddress@example.com>, B Person <b@example.com>'
  printf '%s\n\n%s\n\n%s\n' 'feat: x' "$LONG" "$trailer" > "$TEST_TMP/in.txt"
  run wrap_commit_body < "$TEST_TMP/in.txt"
  assert_success
  assert_line --index $((${#lines[@]} - 1)) "$trailer"
}

@test "wrap_commit_body: mid-body colon prose still wraps" {
  printf '%s\n\n%s\n\n%s\n' 'feat: x' "Verified: $LONG" 'Refs ABC-123' > "$TEST_TMP/in.txt"
  width=$(wrap_commit_body < "$TEST_TMP/in.txt" | max_body_width)
  [ "$width" -le 72 ]
  run wrap_commit_body < "$TEST_TMP/in.txt"
  assert_line --index $((${#lines[@]} - 1)) 'Refs ABC-123'
}

@test "wrap_commit_body: long URL not broken" {
  url="https://example.com/$(printf 'a%.0s' {1..90})"
  printf '%s\n\n%s\n' 'feat: x' "See $url for details." > "$TEST_TMP/in.txt"
  run wrap_commit_body < "$TEST_TMP/in.txt"
  assert_success
  assert_output --partial "$url"
}
