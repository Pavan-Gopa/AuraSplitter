"""Resolve ffmpeg/ffprobe binaries for GUI and minimal-PATH launches.

macOS apps and detached backends often start with PATH=/usr/bin:/bin:/usr/sbin:/sbin,
which does not include Homebrew. Bare "ffmpeg" then fails with FileNotFoundError.
"""

from __future__ import annotations

import os
import shutil
from functools import lru_cache
from pathlib import Path

_CANDIDATE_DIRS = (
    Path("/opt/homebrew/bin"),
    Path("/usr/local/bin"),
    Path("/usr/bin"),
    Path("/bin"),
)


@lru_cache(maxsize=1)
def ffmpeg_bin() -> str:
    return _resolve("ffmpeg")


@lru_cache(maxsize=1)
def ffprobe_bin() -> str:
    return _resolve("ffprobe")


def _resolve(name: str) -> str:
    env_key = f"KIRTAN_SPLITTER_{name.upper()}"
    env_value = os.environ.get(env_key) or os.environ.get(name.upper())
    if env_value:
        path = Path(env_value).expanduser()
        if path.is_file() and os.access(path, os.X_OK):
            return str(path)

    found = shutil.which(name)
    if found:
        return found

    for directory in _CANDIDATE_DIRS:
        candidate = directory / name
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)

    # Last resort: keep the bare name so error messages stay familiar.
    return name
