"""Compatibility shims for third-party MLX packages inside a signed .app.

mlx-audio-io refuses to load `_core*.so` when its bytes no longer match the
wheel RECORD. Developer ID codesign (required for Gatekeeper) rewrites those
bytes. The app bundle signature is the integrity check in that case.
"""
from __future__ import annotations

import logging
from pathlib import Path
from typing import Any

logger = logging.getLogger("kirtan_backend.mlx_compat")

_RECORD_MISMATCH_MARK = "hash mismatch vs dist-info RECORD"
_APP_BUNDLE_MARK = ".app/Contents/"


def should_ignore_record_hash_mismatch(error: BaseException, native_path: Path | str) -> bool:
    if _RECORD_MISMATCH_MARK not in str(error):
        return False
    return _APP_BUNDLE_MARK in str(native_path)


def apply_mlx_audio_io_app_bundle_compat() -> None:
    try:
        import mlx_audio_io._native_loader as loader
    except Exception:
        return

    current = getattr(loader, "verify_record_hash", None)
    if current is None or getattr(current, "_aura_patched", False):
        return

    def verify_record_hash(native_path: Any) -> None:
        try:
            current(native_path)
        except RuntimeError as exc:
            if not should_ignore_record_hash_mismatch(exc, native_path):
                raise
            logger.warning(
                "Ignoring mlx-audio-io RECORD hash mismatch for app-bundled native extension %s",
                native_path,
            )

    verify_record_hash._aura_patched = True  # type: ignore[attr-defined]
    loader.verify_record_hash = verify_record_hash
