from __future__ import annotations

import base64
import hashlib
import importlib.util
import shutil
import tempfile
from pathlib import Path

import pytest


def _load_rewriter():
    path = Path(__file__).resolve().parents[1] / "script" / "rewrite_distinfo_record_hashes.py"
    spec = importlib.util.spec_from_file_location("rewrite_distinfo_record_hashes", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _sha256_record(data: bytes) -> str:
    digest = hashlib.sha256(data).digest()
    return base64.urlsafe_b64encode(digest).decode("ascii").rstrip("=")


def test_rewriter_updates_stale_native_extension_hash(tmp_path: Path):
    rewriter = _load_rewriter()
    site = tmp_path / "site-packages"
    pkg = site / "demo_pkg"
    dist = site / "demo_pkg-1.0.dist-info"
    pkg.mkdir(parents=True)
    dist.mkdir()

    native = pkg / "_core.so"
    native.write_bytes(b"original-bytes")
    original_hash = _sha256_record(b"original-bytes")
    (dist / "RECORD").write_text(
        "\n".join(
            [
                f"demo_pkg/_core.so,sha256={original_hash},{len(b'original-bytes')}",
                "demo_pkg-1.0.dist-info/RECORD,,",
                "",
            ]
        ),
        encoding="utf-8",
    )

    native.write_bytes(b"signed-bytes-after-codesign")
    updated = rewriter.rewrite_site_packages(site)

    assert updated == 1
    record = (dist / "RECORD").read_text(encoding="utf-8")
    new_hash = _sha256_record(b"signed-bytes-after-codesign")
    assert f"demo_pkg/_core.so,sha256={new_hash},{len(b'signed-bytes-after-codesign')}" in record
    assert "demo_pkg-1.0.dist-info/RECORD,," in record
    assert original_hash not in record


def test_rewriter_is_noop_when_hashes_already_match(tmp_path: Path):
    rewriter = _load_rewriter()
    site = tmp_path / "site-packages"
    pkg = site / "demo_pkg"
    dist = site / "demo_pkg-1.0.dist-info"
    pkg.mkdir(parents=True)
    dist.mkdir()
    payload = b"unchanged"
    (pkg / "mod.py").write_bytes(payload)
    digest = _sha256_record(payload)
    original = f"demo_pkg/mod.py,sha256={digest},{len(payload)}\ndemo_pkg-1.0.dist-info/RECORD,,\n"
    (dist / "RECORD").write_text(original, encoding="utf-8")

    updated = rewriter.rewrite_site_packages(site)
    assert updated == 0
    assert (dist / "RECORD").read_text(encoding="utf-8") == original


def test_rewriter_fixes_real_signed_mlx_audio_io_extension():
    rewriter = _load_rewriter()
    bundled = (
        Path(__file__).resolve().parents[1]
        / "dist"
        / "AuraSplitter.app"
        / "Contents"
        / "Resources"
        / "python"
        / "lib"
        / "python3.11"
        / "site-packages"
    )
    native = bundled / "mlx_audio_io" / "_core.cpython-311-darwin.so"
    record = bundled / "mlx_audio_io-1.3.11.dist-info" / "RECORD"
    if not native.is_file() or not record.is_file():
        pytest.skip("signed app bundle is not present")

    expected_wheel_hash = "feVd2lZX8yKfsydErQSpv579tizZCeMV26qqbvous0w"
    actual = _sha256_record(native.read_bytes())
    assert actual != expected_wheel_hash
    assert expected_wheel_hash in record.read_text(encoding="utf-8")

    with tempfile.TemporaryDirectory() as tmp:
        dest = Path(tmp) / "site-packages"
        dest.mkdir()
        shutil.copytree(bundled / "mlx_audio_io", dest / "mlx_audio_io")
        shutil.copytree(
            bundled / "mlx_audio_io-1.3.11.dist-info",
            dest / "mlx_audio_io-1.3.11.dist-info",
        )
        updated = rewriter.rewrite_site_packages(dest)
        assert updated >= 1
        new_record = (dest / "mlx_audio_io-1.3.11.dist-info" / "RECORD").read_text(encoding="utf-8")
        native_line = next(
            line for line in new_record.splitlines() if line.startswith("mlx_audio_io/_core.cpython-311-darwin.so,")
        )
        assert f"sha256={actual}" in native_line
        assert expected_wheel_hash not in native_line
