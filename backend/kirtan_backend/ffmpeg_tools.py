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


_PATH_AUGMENTED = False


def ensure_ffmpeg_on_path() -> str:
    """Prepend Homebrew / standard dirs to ``os.environ["PATH"]``.

    Third-party libraries used during separation (e.g. ``mlx-audio-separator``
    and its audio I/O backends) invoke ``ffmpeg`` / ``ffprobe`` as *bare*
    commands via ``subprocess``. Those child processes inherit
    ``os.environ["PATH"]`` from the backend process. When the backend is
    launched from a macOS ``.app`` bundle, ``launchd``, or any other context
    with a minimal GUI ``PATH`` (``/usr/bin:/bin:/usr/sbin:/sbin``), Homebrew
    is missing and those calls fail with::

        FileNotFoundError: [Errno 2] No such file or directory: 'ffmpeg'

    Our own code is shielded from this by :func:`_resolve` (which scans
    ``_CANDIDATE_DIRS`` regardless of ``PATH``), but descendant subprocesses
    are not. Augmenting ``PATH`` here makes every child process able to find
    the binaries no matter how the backend was started.

    The function is idempotent and safe to call repeatedly. It is also invoked
    at import time below so the fix is in place before any lazy import of a
    separation library can cache a (missing) binary path.
    """
    global _PATH_AUGMENTED
    if _PATH_AUGMENTED:
        return os.environ.get("PATH", "")

    extra_dirs: list[str] = []
    # Directories that actually contain the resolved binaries (most specific).
    for name in ("ffmpeg", "ffprobe"):
        resolved = _resolve(name)
        if resolved and resolved != name:
            parent = str(Path(resolved).parent)
            if parent and parent not in extra_dirs:
                extra_dirs.append(parent)
    # Standard candidate directories (Homebrew first) as a fallback.
    for directory in _CANDIDATE_DIRS:
        as_str = str(directory)
        if as_str not in extra_dirs:
            extra_dirs.append(as_str)

    current = os.environ.get("PATH", "")
    existing = [part for part in current.split(os.pathsep) if part]

    merged: list[str] = []
    seen: set[str] = set()
    for part in extra_dirs + existing:
        if part not in seen:
            seen.add(part)
            merged.append(part)

    os.environ["PATH"] = os.pathsep.join(merged)
    _PATH_AUGMENTED = True
    return os.environ["PATH"]


# Apply on import so the augmented PATH is visible to any library that is
# imported lazily afterwards (e.g. inside ``separate()``).
ensure_ffmpeg_on_path()
