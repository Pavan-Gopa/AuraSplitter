from __future__ import annotations

import logging
import sys
import types
import wave
from array import array
from pathlib import Path
from types import SimpleNamespace

import numpy as np
import pytest


def _install_fake_separator(monkeypatch, separator_class, audio_load):
    common_module = types.ModuleType("mlx_audio_separator.separator.common_separator")
    common_module.CommonSeparator = separator_class
    separator_module = types.ModuleType("mlx_audio_separator.separator")
    separator_module.common_separator = common_module
    package_module = types.ModuleType("mlx_audio_separator")
    package_module.separator = separator_module

    audio_io_module = types.ModuleType("mlx_audio_io")
    audio_io_module.load = audio_load

    monkeypatch.setitem(sys.modules, "mlx_audio_separator", package_module)
    monkeypatch.setitem(sys.modules, "mlx_audio_separator.separator", separator_module)
    monkeypatch.setitem(sys.modules, "mlx_audio_separator.separator.common_separator", common_module)
    monkeypatch.setitem(sys.modules, "mlx_audio_io", audio_io_module)

from kirtan_backend.mlx_compat import (
    apply_mlx_audio_io_app_bundle_compat,
    apply_mlx_audio_separator_silent_audio_compat,
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


def test_valid_silent_separator_audio_is_tolerated_with_channels_major_shape(monkeypatch, tmp_path, caplog):
    def rejected_load(self, audio_path):
        raise ValueError(f"Audio file {audio_path} is empty or not valid")

    class FakeSeparator:
        load_audio = rejected_load

    calls = []

    def audio_load(audio_path, *, sr, dtype):
        calls.append((audio_path, sr, dtype))
        return np.zeros((44_100, 2), dtype=np.float32), sr

    _install_fake_separator(monkeypatch, FakeSeparator, audio_load)
    apply_mlx_audio_separator_silent_audio_compat()

    separator = FakeSeparator()
    separator.sample_rate = 44_100
    audio_path = tmp_path / "silent.wav"
    with caplog.at_level(logging.WARNING, logger="kirtan_backend.mlx_compat"):
        mix = separator.load_audio(str(audio_path))

    assert mix.shape == (2, 44_100)
    assert mix.dtype == np.float32
    assert np.count_nonzero(mix) == 0
    assert calls == [(str(audio_path), 44_100, "float32")]
    assert any("silent-audio tolerance" in record.message.lower() for record in caplog.records)


def test_zero_frame_separator_audio_still_raises(monkeypatch, tmp_path):
    def rejected_load(self, audio_path):
        raise ValueError(f"Audio file {audio_path} is empty or not valid")

    class FakeSeparator:
        load_audio = rejected_load

    def audio_load(audio_path, *, sr, dtype):
        return np.zeros((0, 2), dtype=np.float32), sr

    _install_fake_separator(monkeypatch, FakeSeparator, audio_load)
    apply_mlx_audio_separator_silent_audio_compat()

    separator = FakeSeparator()
    separator.sample_rate = 44_100
    audio_path = tmp_path / "empty.wav"
    with pytest.raises(ValueError, match="is empty or not valid"):
        separator.load_audio(str(audio_path))


def test_apply_mlx_audio_separator_silent_audio_compat_is_idempotent(monkeypatch):
    calls = {"original": 0, "fallback": 0}

    def rejected_load(self, audio_path):
        calls["original"] += 1
        raise ValueError(f"Audio file {audio_path} is empty or not valid")

    class FakeSeparator:
        load_audio = rejected_load

    def audio_load(audio_path, *, sr, dtype):
        calls["fallback"] += 1
        return np.zeros((8, 2), dtype=np.float32), sr

    _install_fake_separator(monkeypatch, FakeSeparator, audio_load)
    apply_mlx_audio_separator_silent_audio_compat()
    patched_load = FakeSeparator.load_audio
    apply_mlx_audio_separator_silent_audio_compat()

    assert FakeSeparator.load_audio is patched_load

    separator = FakeSeparator()
    separator.sample_rate = 44_100
    mix = separator.load_audio("silent.wav")
    assert mix.shape == (2, 8)
    assert calls == {"original": 1, "fallback": 1}


def test_apply_mlx_audio_separator_silent_audio_compat_absent_libraries(monkeypatch):
    monkeypatch.setitem(sys.modules, "mlx_audio_separator", None)
    monkeypatch.setitem(sys.modules, "mlx_audio_separator.separator.common_separator", None)
    monkeypatch.setitem(sys.modules, "mlx_audio_io", None)

    res = apply_mlx_audio_separator_silent_audio_compat()
    assert res is None


def test_apply_mlx_audio_separator_silent_audio_compat_prepare_mix(monkeypatch, tmp_path):
    def rejected_prepare_mix(self, audio_path):
        raise ValueError(f"Audio file {audio_path} is empty or not valid")

    class FakeSeparatorPrepareMix:
        prepare_mix = rejected_prepare_mix

    def audio_load(audio_path, *, sr, dtype):
        return np.zeros((100, 2), dtype=np.float32), sr

    _install_fake_separator(monkeypatch, FakeSeparatorPrepareMix, audio_load)
    apply_mlx_audio_separator_silent_audio_compat()

    separator = FakeSeparatorPrepareMix()
    separator.sample_rate = 44_100
    audio_path = tmp_path / "silent.wav"
    mix = separator.prepare_mix(str(audio_path))
    assert mix.shape == (2, 100)


def test_apply_mlx_audio_separator_silent_audio_compat_mono_audio_shaping(monkeypatch, tmp_path):
    def rejected_load(self, audio_path):
        raise ValueError(f"Audio file {audio_path} is empty or not valid")

    class FakeSeparator:
        load_audio = rejected_load

    def mono_audio_load(audio_path, *, sr, dtype):
        return np.zeros(50, dtype=np.float32), sr

    _install_fake_separator(monkeypatch, FakeSeparator, mono_audio_load)
    apply_mlx_audio_separator_silent_audio_compat()

    separator = FakeSeparator()
    separator.sample_rate = 44_100
    audio_path = tmp_path / "mono_silent.wav"
    mix = separator.load_audio(str(audio_path))
    assert mix.shape == (2, 50)
    assert np.count_nonzero(mix) == 0


def test_apply_mlx_audio_separator_silent_audio_compat_warning_stability(monkeypatch, tmp_path, caplog):
    def rejected_load(self, audio_path):
        raise ValueError(f"Audio file {audio_path} is empty or not valid")

    class FakeSeparator:
        load_audio = rejected_load

    def audio_load(audio_path, *, sr, dtype):
        return np.zeros((200, 2), dtype=np.float32), sr

    _install_fake_separator(monkeypatch, FakeSeparator, audio_load)
    apply_mlx_audio_separator_silent_audio_compat()

    separator = FakeSeparator()
    separator.sample_rate = 44_100
    audio_path = tmp_path / "silent_stable.wav"

    with caplog.at_level(logging.WARNING, logger="kirtan_backend.mlx_compat"):
        separator.load_audio(str(audio_path))

    records = [r for r in caplog.records if r.name == "kirtan_backend.mlx_compat"]
    assert len(records) == 1
    assert records[0].levelno == logging.WARNING
    assert records[0].message == f"Applying silent-audio tolerance for valid silent input {audio_path}"


def _write_wav(path, frames, *, channels=2, sample_rate=44_100, amplitude=0):
    """Write a real, decodable PCM16 wav file (silent by default)."""
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(channels)
        handle.setsampwidth(2)
        handle.setframerate(sample_rate)
        if frames:
            handle.writeframes(array("h", [amplitude] * (frames * channels)).tobytes())
    return path


def _real_patched_loader():
    """Return the real, already-patched mlx-audio-separator loader and a stub separator."""
    pytest.importorskip("mlx_audio_separator")

    import kirtan_backend  # noqa: F401  importing the package applies the shims
    from mlx_audio_separator.separator.common_separator import CommonSeparator

    method_name = "load_audio" if getattr(CommonSeparator, "load_audio", None) else "prepare_mix"
    loader = getattr(CommonSeparator, method_name)
    assert getattr(loader, "_aura_patched", False) is True
    separator = SimpleNamespace(
        sample_rate=44_100,
        input_encoding=None,
        logger=logging.getLogger("tests.real_separator"),
    )
    return loader, separator


def test_package_import_applies_both_shims_with_independent_patch_markers():
    pytest.importorskip("mlx_audio_separator")
    pytest.importorskip("mlx_audio_io")

    import kirtan_backend
    import mlx_audio_io._native_loader as native_loader
    from mlx_audio_separator.separator.common_separator import CommonSeparator

    method_name = "load_audio" if getattr(CommonSeparator, "load_audio", None) else "prepare_mix"
    separator_loader = getattr(CommonSeparator, method_name)
    record_hash_check = native_loader.verify_record_hash

    # Both shims tag their own wrapper; the shared attribute name must not make
    # one shim believe the other's target is already patched.
    assert getattr(separator_loader, "_aura_patched", False) is True
    assert getattr(record_hash_check, "_aura_patched", False) is True
    assert separator_loader is not record_hash_check

    kirtan_backend.apply_mlx_audio_separator_silent_audio_compat()
    kirtan_backend.apply_mlx_audio_io_app_bundle_compat()

    assert getattr(CommonSeparator, method_name) is separator_loader
    assert native_loader.verify_record_hash is record_hash_check


def test_real_separator_tolerates_silent_stereo_wav(tmp_path, caplog):
    loader, separator = _real_patched_loader()
    audio_path = _write_wav(tmp_path / "silent_stereo.wav", 44_100)

    with caplog.at_level(logging.WARNING, logger="kirtan_backend.mlx_compat"):
        mix = loader(separator, str(audio_path))

    assert mix.shape == (2, 44_100)
    assert mix.dtype == np.float32
    assert np.count_nonzero(mix) == 0
    records = [r for r in caplog.records if r.name == "kirtan_backend.mlx_compat"]
    assert len(records) == 1
    assert records[0].message == (
        f"Applying silent-audio tolerance for valid silent input {audio_path}"
    )


def test_real_separator_tolerates_silent_mono_wav_needing_resample(tmp_path):
    loader, separator = _real_patched_loader()
    audio_path = _write_wav(
        tmp_path / "silent_mono_8k.wav", 4_000, channels=1, sample_rate=8_000
    )

    mix = loader(separator, str(audio_path))

    # Channels-major, resampled from 8 kHz to the separator's 44.1 kHz.
    assert mix.shape == (1, 22_050)
    assert np.count_nonzero(mix) == 0


def test_real_separator_leaves_non_silent_wav_untouched(tmp_path, caplog):
    loader, separator = _real_patched_loader()
    audio_path = _write_wav(tmp_path / "loud.wav", 1_000, amplitude=8_000)

    with caplog.at_level(logging.WARNING, logger="kirtan_backend.mlx_compat"):
        mix = loader(separator, str(audio_path))

    assert mix.shape == (2, 1_000)
    assert np.count_nonzero(mix) == 2_000
    assert [r for r in caplog.records if r.name == "kirtan_backend.mlx_compat"] == []


def test_real_separator_zero_frame_wav_still_raises(tmp_path, caplog):
    loader, separator = _real_patched_loader()
    audio_path = _write_wav(tmp_path / "zero_frames.wav", 0)

    with caplog.at_level(logging.WARNING, logger="kirtan_backend.mlx_compat"):
        with pytest.raises(ValueError, match="is empty or not valid"):
            loader(separator, str(audio_path))

    assert [r for r in caplog.records if r.name == "kirtan_backend.mlx_compat"] == []


def test_real_separator_undecodable_file_still_raises(tmp_path, caplog):
    loader, separator = _real_patched_loader()
    audio_path = tmp_path / "garbage.wav"
    audio_path.write_bytes(b"this is not audio at all, just text bytes\n" * 8)

    with caplog.at_level(logging.WARNING, logger="kirtan_backend.mlx_compat"):
        with pytest.raises((RuntimeError, ValueError)) as excinfo:
            loader(separator, str(audio_path))

    assert "garbage.wav" in str(excinfo.value)
    assert [r for r in caplog.records if r.name == "kirtan_backend.mlx_compat"] == []


def test_silent_chunk_inside_chunked_file_no_longer_aborts_the_run(tmp_path, caplog):
    """The reported scenario: one all-silent chunk must not kill the whole file."""
    loader, separator = _real_patched_loader()
    from mlx_audio_separator.separator.audio_chunking import AudioChunker

    sample_rate = 8_000
    separator.sample_rate = sample_rate
    chunk_count = 7
    silent_chunk_index = 3

    samples = array("h")
    for chunk_index in range(chunk_count):
        amplitude = 0 if chunk_index == silent_chunk_index else 8_000
        samples.extend([amplitude] * (sample_rate * 2))

    source = tmp_path / "long_kirtan.wav"
    with wave.open(str(source), "wb") as handle:
        handle.setnchannels(2)
        handle.setsampwidth(2)
        handle.setframerate(sample_rate)
        handle.writeframes(samples.tobytes())

    chunker = AudioChunker(1.0, logging.getLogger("tests.real_chunker"))
    chunk_paths = chunker.split_audio(
        str(source), str(tmp_path / "chunks"), sample_rate=sample_rate
    )
    assert len(chunk_paths) == chunk_count

    with caplog.at_level(logging.WARNING, logger="kirtan_backend.mlx_compat"):
        mixes = [loader(separator, chunk_path) for chunk_path in chunk_paths]

    assert [mix.shape for mix in mixes] == [(2, sample_rate)] * chunk_count
    assert np.count_nonzero(mixes[silent_chunk_index]) == 0
    assert all(
        np.count_nonzero(mix)
        for index, mix in enumerate(mixes)
        if index != silent_chunk_index
    )

    records = [r for r in caplog.records if r.name == "kirtan_backend.mlx_compat"]
    assert len(records) == 1
    assert f"chunk_{silent_chunk_index:04d}.wav" in records[0].message


def test_real_separator_mono_shape_is_library_convention_not_shim_artifact(
    tmp_path, caplog
):
    """Silent mono yields (1, N) because that is what the untouched loader yields."""
    loader, separator = _real_patched_loader()
    audio_path = _write_wav(tmp_path / "loud_mono.wav", 1_000, channels=1, amplitude=8_000)

    with caplog.at_level(logging.WARNING, logger="kirtan_backend.mlx_compat"):
        mix = loader(separator, str(audio_path))

    # No tolerance warning: this file decodes through the original code path, so
    # the shape below is the library's mono contract, matched by the silent path.
    assert [r for r in caplog.records if r.name == "kirtan_backend.mlx_compat"] == []
    assert mix.shape == (1, 1_000)
    assert np.count_nonzero(mix) == 1_000
