#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
load '../helpers/common'

setup() {
  load_bats_libs
  TEST_DIR="$(mktemp -d)"
  TEST_REPO="$(make_test_repo)"
  git -C "$TEST_REPO" branch -M main
  git -C "$TEST_REPO" checkout -q -b feature/clipboard
  cd "$TEST_REPO"

  STUB_BIN="${TEST_DIR}/bin"
  CLIPBOARD_FILE="${TEST_DIR}/clipboard.txt"
  mkdir -p "$STUB_BIN"
  cat >"${STUB_BIN}/pbcopy" <<EOF
#!/usr/bin/env bash
cat >"${CLIPBOARD_FILE}"
EOF
  chmod +x "${STUB_BIN}/pbcopy"
  export PATH="${STUB_BIN}:${PATH}"
  export CLIPBOARD_FILE

  source "${REPO_ROOT}/lib/ai-common.sh"
  source "${REPO_ROOT}/bin/git-ai"

  run_provider() {
    if [[ "$1" == "commit" ]]; then
      printf 'feat: generated commit title\n\n- generated commit bullet\n'
    else
      printf 'feat: generated pr title\n\n### Features\n- generated pr bullet\n'
    fi
  }
  export -f run_provider

  echo "hello" > file.txt
  git add file.txt
}

teardown() {
  cd /tmp
  rm -rf "$TEST_REPO" "$TEST_DIR"
}

@test "cmd_commit: interactive mode auto-copies generated message via pbcopy" {
  GIT_EDITOR="touch" GIT_AI_FORCE_INTERACTIVE=1 run --separate-stderr cmd_commit "codex:gpt-5.4-mini"

  assert_success
  assert_stderr --partial "git-ai: copied to clipboard"
  [ -f "$CLIPBOARD_FILE" ]
  run cat "$CLIPBOARD_FILE"
  assert_success
  assert_output $'feat: generated commit title\n\n- generated commit bullet'
}

@test "cmd_commit: interactive mode updates clipboard when editor modifies message" {
  cat >"${STUB_BIN}/edit-msg" <<'EOF'
#!/usr/bin/env bash
printf 'fix: edited in buffer\n' >"$1"
EOF
  chmod +x "${STUB_BIN}/edit-msg"

  GIT_EDITOR="${STUB_BIN}/edit-msg" GIT_AI_FORCE_INTERACTIVE=1 run --separate-stderr cmd_commit "codex:gpt-5.4-mini"

  assert_success
  assert_stderr --partial "git-ai: copied to clipboard"
  [ -f "$CLIPBOARD_FILE" ]
  run cat "$CLIPBOARD_FILE"
  assert_success
  assert_output "fix: edited in buffer"
}

@test "cmd_commit: non-interactive mode (Lazygit capture) does not invoke pbcopy" {
  GIT_AI_FORCE_INTERACTIVE=0 run cmd_commit "codex:gpt-5.4-mini"

  assert_success
  assert_output $'feat: generated commit title\n\n- generated commit bullet'
  [ ! -e "$CLIPBOARD_FILE" ]
}

@test "cmd_pr: interactive mode copies clean formatted PR text on fresh and cached runs" {
  git commit -q -m "feat: add file"

  save_cached_pr "$(git rev-parse --git-dir)" "feature/clipboard" "main" \
    $'feat: old pr title\n\n### Features\n- old bullet' \
    "0000000000000000000000000000000000000000"

  GIT_AI_FORCE_INTERACTIVE=1 run --separate-stderr cmd_pr codex gpt-5.4-mini --base main

  assert_success
  assert_output --partial "**Changes since previous draft**"
  assert_stderr --partial "git-ai: copied to clipboard"
  [ -f "$CLIPBOARD_FILE" ]
  run cat "$CLIPBOARD_FILE"
  assert_success
  assert_output $'feat: generated pr title\n\n### Features\n- generated pr bullet'
  refute_output --partial "**Changes since previous draft**"

  rm -f "$CLIPBOARD_FILE"
  GIT_AI_FORCE_INTERACTIVE=1 run --separate-stderr cmd_pr codex gpt-5.4-mini --base main

  assert_success
  assert_stderr --partial "git-ai: copied to clipboard"
  [ -f "$CLIPBOARD_FILE" ]
  run cat "$CLIPBOARD_FILE"
  assert_success
  assert_output $'feat: generated pr title\n\n### Features\n- generated pr bullet'
}

@test "cmd_pr: non-interactive mode does not invoke pbcopy" {
  git commit -q -m "feat: add file"

  GIT_AI_FORCE_INTERACTIVE=0 run cmd_pr codex gpt-5.4-mini --base main

  assert_success
  assert_output --partial $'feat: generated pr title\n\n### Features\n- generated pr bullet'
  [ ! -e "$CLIPBOARD_FILE" ]
}

@test "_copy_to_clipboard: silent no-op when no clipboard tool is on PATH" {
  local empty_bin="${TEST_DIR}/empty-bin"
  mkdir -p "$empty_bin"

  run bash -c 'source "$1/lib/ai-common.sh"; PATH="$2" _copy_to_clipboard "some text"; printf "rc=%s\n" "$?"' _ "$REPO_ROOT" "$empty_bin"

  assert_success
  assert_output "rc=0"
}

@test "cmd_commit: succeeds with no clipboard tool on PATH" {
  local no_clip="${TEST_DIR}/no-clip-bin"
  mkdir -p "$no_clip"
  for c in git mktemp rm cat true stat touch dirname readlink python3; do
    ln -s "$(command -v "$c")" "$no_clip/$c"
  done

  local old_path="$PATH"
  export PATH="$no_clip"
  GIT_EDITOR=touch GIT_AI_FORCE_INTERACTIVE=1 run cmd_commit "codex:gpt-5.4-mini"
  export PATH="$old_path"

  assert_success
  refute_output --partial "copied to clipboard"
  run git log -1 --format=%s
  assert_output "feat: generated commit title"
}
