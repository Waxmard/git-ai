#!/bin/bash
# check-line-limit.sh - fail if any hand-written source file exceeds the limit.
#
# Keeps modules small enough to read in one sitting; the cap is what forced the
# lib/ai-common.sh + lib/setup.sh + _git.py splits. Counted: hand-written shell
# and Python source. Out of scope: generated docs, prompt .txt, vendored code,
# and tests (fixtures legitimately run long).
#
# Usage:
#   scripts/check-line-limit.sh            # scan the repo source set (CI)
#   scripts/check-line-limit.sh FILE...    # check only the given files (lefthook)
#
# Override the cap with GIT_AI_LINE_LIMIT (default 800).
set -euo pipefail

LIMIT="${GIT_AI_LINE_LIMIT:-800}"

# Is PATH one of the source files this check governs?
is_source() {
  case "$1" in
    bin/git-ai | bin/aigit) return 0 ;;
    lib/*.sh) return 0 ;;
    python/git_ai/*.py) return 0 ;;
    scripts/*.sh | scripts/*.py) return 0 ;;
    *) return 1 ;;
  esac
}

# The full governed set, for the no-argument (CI) scan.
collect_default() {
  printf '%s\n' bin/git-ai bin/aigit
  ls lib/*.sh python/git_ai/*.py scripts/*.sh scripts/*.py 2>/dev/null
}

files=()
if [[ $# -gt 0 ]]; then
  for f in "$@"; do
    is_source "$f" && [[ -f "$f" ]] && files+=("$f")
  done
else
  while IFS= read -r f; do
    [[ -f "$f" ]] && files+=("$f")
  done < <(collect_default)
fi

status=0
checked=0
for f in "${files[@]:-}"; do
  [[ -z "$f" ]] && continue
  checked=$((checked + 1))
  n=$(wc -l <"$f")
  if ((n > LIMIT)); then
    printf 'LINE LIMIT: %s has %d lines (max %d)\n' "$f" "$n" "$LIMIT" >&2
    status=1
  fi
done

if ((status != 0)); then
  printf '\nSplit the file(s) above into focused modules. For shell, mirror the\n' >&2
  printf 'lib/ai-common.sh umbrella pattern (a thin entry that sources siblings).\n' >&2
  exit 1
fi

printf 'line-limit OK (<= %d lines): %d files checked\n' "$LIMIT" "$checked"
