"""In-tree PEP 517 build backend.

The CLI is the Bash program at ``bin/git-ai`` + ``lib/*.sh``, which live at the
repo root (the canonical source shared with the npm package and ``make
install``). The wheel needs them *under* the Python package so they install
alongside ``git_ai``. This backend copies them into ``python/git_ai/_sh/``
before each build, so the wheel's Bash is always a fresh build output and never
drifts from the root sources. Everything else delegates to setuptools.
"""

from __future__ import annotations

import shutil
from pathlib import Path

from setuptools import build_meta as _orig
from setuptools.build_meta import *  # noqa: F403  re-export the PEP 517 hooks

_ROOT = Path(__file__).resolve().parent
_DEST = _ROOT / "python" / "git_ai" / "_sh"


def _sync_bash() -> None:
    """Mirror root bin/ + lib/ into the package as fresh build output."""
    if _DEST.exists():
        shutil.rmtree(_DEST)
    for sub in ("bin", "lib"):
        shutil.copytree(_ROOT / sub, _DEST / sub)


def build_wheel(wheel_directory, config_settings=None, metadata_directory=None):
    _sync_bash()
    return _orig.build_wheel(wheel_directory, config_settings, metadata_directory)


def build_editable(wheel_directory, config_settings=None, metadata_directory=None):
    _sync_bash()
    return _orig.build_editable(wheel_directory, config_settings, metadata_directory)


def build_sdist(sdist_directory, config_settings=None):
    _sync_bash()
    return _orig.build_sdist(sdist_directory, config_settings)
