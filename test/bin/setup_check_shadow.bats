#!/usr/bin/env bats
load '../helpers/common'

GIT_AI="${REPO_ROOT}/bin/git-ai"

setup() {
  load_bats_libs
  TEST_DIR="$(mktemp -d)"
  # Sourcing bin/git-ai defines its functions without running dispatch.
  source "$GIT_AI"

  # Stub npm so the helper sees a controllable "global" install. The stub
  # echoes the dirs the function asks for and records `npm rm` invocations.
  mkdir -p "$TEST_DIR/bin"
  export NPM_GROOT="$TEST_DIR/groot"
  export NPM_GPREFIX="$TEST_DIR/prefix"
  export NPM_RMLOG="$TEST_DIR/rm.log"
  cat >"$TEST_DIR/bin/npm" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "root -g")   printf '%s\n' "$NPM_GROOT" ;;
  "prefix -g") printf '%s\n' "$NPM_GPREFIX" ;;
  "rm -g")     printf 'RM:%s\n' "$3" >>"$NPM_RMLOG" ;;
esac
EOF
  chmod +x "$TEST_DIR/bin/npm"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "_setup_check_shadow: no-ops silently when npm is absent" {
  # A PATH with no npm at all → command -v npm fails → early return, no output.
  PATH="$TEST_DIR/empty" run _setup_check_shadow
  assert_success
  assert_output ""
}

@test "_setup_check_shadow: no-ops when the npm package is not installed" {
  # groot has no waxmard-git-ai dir → nothing to offer.
  PATH="$TEST_DIR/bin:$PATH" run _setup_check_shadow
  assert_success
  assert_output ""
}

@test "_setup_check_shadow: warns but does not remove when declined" {
  mkdir -p "$NPM_GROOT/waxmard-git-ai"
  PATH="$TEST_DIR/bin:$PATH" run _setup_check_shadow <<<"n"
  assert_success
  assert_output --partial "an npm-global git-ai is also installed"
  assert_output --partial "Left as-is"
  [ ! -f "$NPM_RMLOG" ]
}

@test "_setup_check_shadow: flags PATH shadow and removes when accepted" {
  mkdir -p "$NPM_GROOT/waxmard-git-ai"
  # Make the npm bin's git-ai what PATH resolves → shadow note fires.
  mkdir -p "$NPM_GPREFIX/bin"
  printf '#!/bin/sh\n' >"$NPM_GPREFIX/bin/git-ai"
  chmod +x "$NPM_GPREFIX/bin/git-ai"
  PATH="$NPM_GPREFIX/bin:$TEST_DIR/bin:$PATH" run _setup_check_shadow <<<"y"
  assert_success
  assert_output --partial "shadows this install on your PATH"
  assert_output --partial "Removed."
  assert_equal "$(cat "$NPM_RMLOG")" "RM:waxmard-git-ai"
}
