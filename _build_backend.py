"""In-tree PEP 517 build backend.

The canonical Bash CLI (``bin/git-ai`` + ``lib/*.sh``) lives at the repo root,
shared with the npm package and ``make install``, but the wheel needs it under
the Python package. This copies it into ``python/git_ai/_sh/`` before each
build so it can't drift. Everything else delegates to setuptools.
"""

from __future__ import annotations

import shutil
from pathlib import Path

from setuptools import build_meta as _orig
from setuptools.build_meta import *  # noqa: F403  re-export the PEP 517 hooks

_ROOT = Path(__file__).resolve().parent
_DEST = _ROOT / "python" / "git_ai" / "_sh"


def _sync_bash() -> None:
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
