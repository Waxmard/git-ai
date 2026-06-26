#!/bin/bash
# setup-shadow.sh - shadow-install detection for the git-ai setup wizard.
# Sourced by lib/setup.sh (umbrella). Detects other git-ai installs that may
# shadow this one on PATH and offers removal, acting only on installs we can
# attribute to a package manager: npm global, pipx, or uv tool.

# Detect other git-ai installs that may shadow this one and offer removal. Acts
# only on installs we can attribute to a package manager — npm global, or the
# pip CLI vectors (pipx / uv tool); anything else on PATH we leave alone. Each
# check is best-effort and silent when its tool/duplicate is absent.
_setup_check_shadow() {
  _setup_check_shadow_npm
  # Don't nag a legitimately pip-installed CLI to "remove" itself: skip the
  # pip-vector checks when we ARE the pip install (bundled bash under _sh/).
  [[ "${BASH_SOURCE[0]%/lib/setup-shadow.sh}" == */git_ai/_sh ]] && return 0
  _setup_check_shadow_pyx pipx "list --short" "uninstall"
  _setup_check_shadow_pyx uv "tool list" "tool uninstall"
}

# pipx- or uv-tool-managed waxmard-git-ai. $1 = tool, $2 = list args, $3 =
# uninstall args (run as "$tool $3 waxmard-git-ai").
_setup_check_shadow_pyx() {
  local tool="$1" list_args="$2" uninstall_args="$3" ans
  command -v "$tool" >/dev/null 2>&1 || return 0
  # shellcheck disable=SC2086  # word-splitting the subcommand args is intended
  "$tool" $list_args 2>/dev/null | grep -qw waxmard-git-ai || return 0

  printf 'Heads up: a %s-managed git-ai is also installed (waxmard-git-ai).\n' "$tool"
  read -rp "  Remove it with \"$tool $uninstall_args waxmard-git-ai\"? [y/N]: " ans
  case "$ans" in
    y | Y | yes | Yes)
      # shellcheck disable=SC2086
      if "$tool" $uninstall_args waxmard-git-ai; then
        printf '  Removed. Re-open your shell so PATH re-resolves git-ai.\n\n'
      else
        printf '  Removal failed — remove it manually.\n\n'
      fi
      ;;
    *) printf '  Left as-is. Ensure ~/.local/bin precedes it on PATH.\n\n' ;;
  esac
}

# A stale `waxmard-git-ai` npm global.
_setup_check_shadow_npm() {
  command -v npm >/dev/null 2>&1 || return 0
  local groot
  groot=$(npm root -g 2>/dev/null) || return 0
  [[ -n "$groot" && -d "$groot/waxmard-git-ai" ]] || return 0

  printf 'Heads up: an npm-global git-ai is also installed:\n'
  printf '  %s\n' "$groot/waxmard-git-ai"

  # Note when that npm copy is what PATH actually resolves (i.e. it shadows the
  # make-install symlink). npm's bin dir is $(npm prefix -g)/bin.
  local gprefix on_path
  gprefix=$(npm prefix -g 2>/dev/null)
  on_path=$(command -v git-ai 2>/dev/null)
  if [[ -n "$gprefix" && "$on_path" == "$gprefix/bin/git-ai" ]]; then
    printf '  It currently shadows this install on your PATH.\n'
  fi

  local ans
  read -rp '  Remove it with "npm rm -g waxmard-git-ai"? [y/N]: ' ans
  case "$ans" in
    y | Y | yes | Yes)
      if npm rm -g waxmard-git-ai; then
        printf '  Removed. Re-open your shell so PATH re-resolves git-ai.\n\n'
      else
        printf '  npm rm failed — remove it manually.\n\n'
      fi
      ;;
    *) printf '  Left as-is. Ensure ~/.local/bin precedes the npm bin on PATH.\n\n' ;;
  esac
}
