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
_SILENT_AUDIO_ERROR_MARK = "is empty or not valid"


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


def apply_mlx_audio_separator_silent_audio_compat() -> None:
    """Allow valid silent files through mlx-audio-separator's loader."""
    try:
        from mlx_audio_separator.separator.common_separator import CommonSeparator
        import mlx_audio_io as mac
    except Exception:
        return

    method_name = "load_audio"
    current = getattr(CommonSeparator, method_name, None)
    if current is None:
        # mlx-audio-separator 0.1.7 calls this method ``prepare_mix``.
        method_name = "prepare_mix"
        current = getattr(CommonSeparator, method_name, None)
    if current is None or getattr(current, "_aura_patched", False):
        return

    def load_audio(self: Any, audio_path: Any) -> Any:
        try:
            return current(self, audio_path)
        except ValueError as original_error:
            if _SILENT_AUDIO_ERROR_MARK not in str(original_error):
                raise

            try:
                import numpy as np

                audio_mx, _ = mac.load(
                    str(audio_path),
                    sr=self.sample_rate,
                    dtype="float32",
                )
                mix = np.array(audio_mx, copy=False)
            except Exception:
                raise original_error.with_traceback(original_error.__traceback__) from None

            if mix.size == 0:
                raise original_error.with_traceback(original_error.__traceback__)

            if mix.ndim == 2:
                mix = mix.T
            if mix.ndim == 1:
                mix = np.stack([mix, mix], axis=0)

            logger.warning(
                "Applying silent-audio tolerance for valid silent input %s",
                audio_path,
            )
            return mix

    load_audio._aura_patched = True  # type: ignore[attr-defined]
    setattr(CommonSeparator, method_name, load_audio)
