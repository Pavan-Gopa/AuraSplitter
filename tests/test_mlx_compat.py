from __future__ import annotations

from pathlib import Path

from kirtan_backend.mlx_compat import (
    apply_mlx_audio_io_app_bundle_compat,
    should_ignore_record_hash_mismatch,
)


def test_ignore_mismatch_only_inside_signed_app_bundle():
    error = RuntimeError(
        "Native extension hash mismatch vs dist-info RECORD.\n"
        "Expected sha256=feVd2lZX8yKfsydErQSpv579tizZCeMV26qqbvous0w, got sha256=abc."
    )
    bundled = Path("/Applications/AuraSplitter.app/Contents/Resources/python/lib/python3.11/site-packages/mlx_audio_io/_core.so")
    venv = Path("/Users/pavan/Documents/AI Projects/AuraSplitter/.venv/lib/python3.11/site-packages/mlx_audio_io/_core.so")

    assert should_ignore_record_hash_mismatch(error, bundled) is True
    assert should_ignore_record_hash_mismatch(error, venv) is False
    assert should_ignore_record_hash_mismatch(RuntimeError("codesign verification failed"), bundled) is False


def test_apply_patches_loader_idempotently(monkeypatch):
    calls = {"n": 0}

    def boom(native_path):
        calls["n"] += 1
        raise RuntimeError(
            "Native extension hash mismatch vs dist-info RECORD.\nExpected sha256=a, got sha256=b."
        )

    class FakeLoader:
        verify_record_hash = staticmethod(boom)

    import sys
    import types

    fake_pkg = types.ModuleType("mlx_audio_io")
    fake_loader = types.ModuleType("mlx_audio_io._native_loader")
    fake_loader.verify_record_hash = boom
    monkeypatch.setitem(sys.modules, "mlx_audio_io", fake_pkg)
    monkeypatch.setitem(sys.modules, "mlx_audio_io._native_loader", fake_loader)

    apply_mlx_audio_io_app_bundle_compat()
    apply_mlx_audio_io_app_bundle_compat()  # idempotent

    bundled = "/tmp/AuraSplitter.app/Contents/Resources/mlx_audio_io/_core.so"
    fake_loader.verify_record_hash(bundled)
    assert calls["n"] == 1

    venv = "/tmp/.venv/lib/python3.11/site-packages/mlx_audio_io/_core.so"
    try:
        fake_loader.verify_record_hash(venv)
        assert False, "venv mismatch must still raise"
    except RuntimeError as exc:
        assert "hash mismatch" in str(exc)
