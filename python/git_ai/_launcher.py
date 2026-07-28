"""Console-script entry point for the pip-installed `git-ai` / `aigit` CLIs.

The real CLI is the wheel-bundled Bash under ``git_ai/_sh/``. This points it at
the installed package (``GIT_AI_PKG_DIR``) and execs it — no Python reimplementation.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path


def main() -> None:
    pkg_dir = Path(__file__).resolve().parent
    cli = pkg_dir / "_sh" / "bin" / "git-ai"
    if not cli.is_file():
        sys.stderr.write(
            f"git-ai: bundled CLI not found at {cli}\n"
            "The wheel may be built incorrectly; reinstall waxmard-git-ai.\n"
        )
        sys.exit(1)

    # Bash resolves prompts/CLIs/data files from this; its repo default
    # (sibling python/git_ai) doesn't exist in the wheel layout. Always
    # overrides a stale GIT_AI_PKG_DIR in the user's environment.
    env = dict(os.environ)
    env["GIT_AI_PKG_DIR"] = str(pkg_dir)

    # Trusted exec: `bash` off PATH, args as a list, no shell interpolation.
    os.execvpe("bash", ["bash", str(cli), *sys.argv[1:]], env)  # noqa: S606


if __name__ == "__main__":
    main()
