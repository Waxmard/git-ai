"""Console-script entry point for the pip-installed `git-ai` / `aigit` CLIs.

The CLI itself is the Bash program under ``bin/git-ai``; the wheel bundles it
(plus ``lib/``) under ``git_ai/_sh/``. This launcher just points the Bash layer
at the installed package (via ``GIT_AI_PKG_DIR``) and execs it, so a
``pip install`` user gets the real tool with no Python reimplementation.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path


def main() -> int:
    pkg_dir = Path(__file__).resolve().parent
    cli = pkg_dir / "_sh" / "bin" / "git-ai"
    if not cli.is_file():
        sys.stderr.write(
            f"git-ai: bundled CLI not found at {cli}\n"
            "The wheel may be built incorrectly; reinstall waxmard-git-ai.\n"
        )
        return 1

    # The Bash layer resolves prompts/CLIs/data files relative to this; the repo
    # default (sibling python/git_ai) does not exist in the wheel layout.
    env = dict(os.environ)
    env.setdefault("GIT_AI_PKG_DIR", str(pkg_dir))

    # Trusted exec: `bash` resolved on PATH (like the rest of the tool) running
    # the wheel-bundled CLI. No shell interpolation — args pass as a list.
    os.execvpe("bash", ["bash", str(cli), *sys.argv[1:]], env)  # noqa: S606


if __name__ == "__main__":
    raise SystemExit(main())
