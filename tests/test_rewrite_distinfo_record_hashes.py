from __future__ import annotations

import base64
import csv
import hashlib
import importlib.util
import shutil
import subprocess
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


def _bundled_site_packages() -> Path | None:
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
    return bundled if bundled.is_dir() else None


def test_release_bundle_record_matches_signed_native_files():
    """Release-pipeline regression: every native binary shipped in the signed
    app bundle must have a RECORD hash matching the bytes actually on disk
    (codesign mutates Mach-O bytes after pip writes RECORD)."""
    bundled = _bundled_site_packages()
    if bundled is None:
        pytest.skip("signed app bundle is not present")

    rewriter = _load_rewriter()
    stale = []
    for dist_info in sorted(bundled.glob("*.dist-info")):
        record = dist_info / "RECORD"
        if not record.is_file():
            continue
        for row in csv.reader(record.read_text(encoding="utf-8").splitlines()):
            if len(row) < 2 or not row[1].lower().startswith("sha256="):
                continue
            target = bundled / row[0]
            if target.suffix not in {".so", ".dylib"} or not target.is_file():
                continue
            if _sha256_record(target.read_bytes()) != row[1].split("=", 1)[1]:
                stale.append(row[0])
    assert stale == [], (
        "Signed bundle ships stale RECORD hashes for native files; "
        f"run script/rewrite_distinfo_record_hashes.py during release: {stale}"
    )


def test_rewriter_fixes_codesigned_mlx_audio_io_extension():
    """Simulate the exact release failure: Developer ID codesign rewrote the
    native extension bytes so RECORD no longer matches; the rewriter must
    repair it. Builds the broken state from the real signed bundle so the
    test is independent of dist/'s current state."""
    rewriter = _load_rewriter()
    bundled = _bundled_site_packages()
    if bundled is None or not (bundled / "mlx_audio_io").is_dir():
        pytest.skip("signed app bundle is not present")

    original_wheel_hash = "feVd2lZX8yKfsydErQSpv579tizZCeMV26qqbvous0w"

    with tempfile.TemporaryDirectory() as tmp:
        dest = Path(tmp) / "site-packages"
        dest.mkdir()
        shutil.copytree(bundled / "mlx_audio_io", dest / "mlx_audio_io")
        shutil.copytree(
            bundled / "mlx_audio_io-1.3.11.dist-info",
            dest / "mlx_audio_io-1.3.11.dist-info",
        )

        # Sign the copied extension like the release pipeline does, then
        # rewind its RECORD entry to the pre-codesign wheel hash.
        subprocess.run(
            ["codesign", "--force", "--sign", "-", str(dest / "mlx_audio_io" / "_core.cpython-311-darwin.so")],
            check=True,
            capture_output=True,
        )
        record_path = dest / "mlx_audio_io-1.3.11.dist-info" / "RECORD"
        native_rel = "mlx_audio_io/_core.cpython-311-darwin.so"
        lines = []
        for line in record_path.read_text(encoding="utf-8").splitlines():
            if line.startswith(native_rel + ","):
                lines.append(f"{native_rel},sha256={original_wheel_hash},501760")
            else:
                lines.append(line)
        record_path.write_text("\n".join(lines) + "\n", encoding="utf-8")

        on_disk = _sha256_record((dest / native_rel).read_bytes())
        assert on_disk != original_wheel_hash, "codesign did not mutate the extension; simulation invalid"

        updated = rewriter.rewrite_site_packages(dest)
        assert updated >= 1
        new_record = record_path.read_text(encoding="utf-8")
        native_line = next(
            line for line in new_record.splitlines() if line.startswith(native_rel + ",")
        )
        assert f"sha256={on_disk}" in native_line
        assert original_wheel_hash not in native_line
