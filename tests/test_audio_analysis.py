import json
import subprocess
import wave
from pathlib import Path

import pytest

import numpy as np

from kirtan_backend import audio_analysis
from kirtan_backend.audio_analysis import _spectrogram
from kirtan_backend.engine import MlxSeparatorEngine


def _sine(frequency: float, sample_rate: int = 22_050, seconds: float = 1.0) -> np.ndarray:
    t = np.arange(int(sample_rate * seconds), dtype=np.float32) / sample_rate
    return np.sin(2 * np.pi * frequency * t).astype(np.float32)


def _dominant_bin(values: list[float], columns: int, bins: int) -> int:
    # Spectrogram values are row-major with bin rows: (bins, columns).
    matrix = np.array(values, dtype=np.float32).reshape(bins, columns)
    return int(np.argmax(matrix.mean(axis=1)))


def test_spectrogram_places_higher_frequency_above_lower_frequency():
    columns = 48
    bins = 96

    low = _spectrogram(_sine(220), columns=columns, bins=bins, sample_rate=22_050)
    high = _spectrogram(_sine(3_520), columns=columns, bins=bins, sample_rate=22_050)

    assert _dominant_bin(low, columns, bins) < _dominant_bin(high, columns, bins)


def test_spectrogram_returns_requested_density():
    values = _spectrogram(_sine(440), columns=128, bins=96, sample_rate=22_050)

    assert len(values) == 128 * 96
    assert max(values) > 0.2


def test_spectrogram_batches_fft_work_for_preview_speed(monkeypatch):
    calls = 0
    real_rfft = audio_analysis.np.fft.rfft

    def counted_rfft(*args, **kwargs):
        nonlocal calls
        calls += 1
        return real_rfft(*args, **kwargs)

    monkeypatch.setattr(audio_analysis.np.fft, "rfft", counted_rfft)

    values = _spectrogram(_sine(440, seconds=2.0), columns=96, bins=64, sample_rate=22_050)

    assert len(values) == 96 * 64
    assert calls <= 8


def test_peak_db_is_computed_from_preview_samples_without_second_ffmpeg_pass():
    assert audio_analysis._peak_db_from_samples(np.array([0.0, -0.5, 1.0], dtype=np.float32)) == 0.0
    assert audio_analysis._peak_db_from_samples(np.zeros(32, dtype=np.float32)) == -120.0


def test_analyze_audio_returns_kirtan_splitter_model_metadata(tmp_path):
    source = tmp_path / "source.wav"
    tagged = tmp_path / "tagged.wav"
    with wave.open(str(source), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(3)
        wav.setframerate(48_000)
        wav.writeframes(b"\0\0\0" * 480)

    subprocess.run(
        [
            "ffmpeg",
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-i",
            str(source),
            "-map",
            "0:a:0",
            "-vn",
            "-c:a",
            "copy",
            "-metadata",
            "encoded_by=KirtanSplitter",
            "-metadata",
            "comment=KirtanSplitter model=Kirtan Pro; checkpoint=BS-Roformer-SW.ckpt; preset=kirtan_pro; process=Heavy 1024",
            str(tagged),
        ],
        check=True,
    )

    result = audio_analysis.analyze_audio(str(tagged), waveform_points=8, spectrogram_columns=8, spectrogram_bins=8)

    assert result["sampleRate"] == 48_000
    assert result["bitDepth"] == 24
    assert result["separationModelName"] == "Kirtan Pro"
    assert result["separationModelCheckpoint"] == "BS-Roformer-SW.ckpt"
    assert result["separationPresetID"] == "kirtan_pro"
    assert result["separationProcessPresetTitle"] == "Heavy 1024"


def test_spectrogram_values_use_row_major_bin_row_layout():
    columns = 48
    bins = 24

    values = _spectrogram(_sine(3_520), columns=columns, bins=bins, sample_rate=22_050)

    # Row-major, bin rows: values[bin * columns + column]. Under this layout a
    # single frequency bin maps to one contiguous run of samples (per column),
    # not a stride scattered across the whole array (which a column-major
    # flatten would produce). The dominant tone bin is checked; its interior
    # columns (excluding the symmetric first/last-column edge artifact) must
    # form a single contiguous run.
    arr = np.array(values, dtype=np.float32).reshape(bins, columns)
    threshold = float(arr.max()) * 0.6
    dominant_bin = int(np.argmax(arr.mean(axis=1)))
    assert arr[dominant_bin].max() > threshold

    run = [
        i
        for i, v in enumerate(values)
        if (i // columns) == dominant_bin
        and 1 <= (i % columns) <= columns - 2
        and v > threshold
    ]
    assert run == list(range(dominant_bin * columns + 1, dominant_bin * columns + columns - 1))


def test_source_audio_format_uses_single_ffprobe_json_probe(monkeypatch, tmp_path):
    engine = MlxSeparatorEngine(str(tmp_path))
    probe_calls: list[list[str]] = []

    def fake_check_output(args, *args_, **kwargs):
        probe_calls.append(list(args))
        return json.dumps(
            {
                "streams": [
                    {
                        "channels": 2,
                        "sample_rate": 44100,
                        "bits_per_raw_sample": 16,
                        "sample_fmt": "s16",
                        "codec_name": "pcm_s16le",
                    }
                ]
            }
        )

    monkeypatch.setattr(subprocess, "check_output", fake_check_output)

    spec = engine._source_audio_format(Path(tmp_path / "song.wav"))

    # Exactly one probe, and it is a single JSON probe (not four scalar probes).
    assert len(probe_calls) == 1
    assert "json" in probe_calls[0]
    assert spec.channels == 2
    assert spec.sample_rate == 44100
    assert spec.bit_depth == 16
    assert spec.codec_name == "pcm_s16le"


def test_write_and_read_analysis_ksbin_round_trips_layout():
    waveform = [0.0, 0.5, 1.0, 0.25]
    columns = 8
    bins = 4
    spectrogram = [float((b * columns + c) % 7) / 7.0 for b in range(bins) for c in range(columns)]

    path = audio_analysis.write_analysis_ksbin(waveform, spectrogram, columns, bins)
    try:
        payload = audio_analysis.read_analysis_ksbin(path)
    finally:
        Path(path).unlink()

    assert payload["spectrogram"]["columns"] == columns
    assert payload["spectrogram"]["bins"] == bins
    assert payload["waveformPeaks"] == pytest.approx(waveform)
    assert payload["spectrogram"]["values"] == pytest.approx(spectrogram)


def test_analyze_audio_writes_ksbin_in_happy_path(tmp_path):
    source = tmp_path / "source.wav"
    with wave.open(str(source), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(22_050)
        wav.writeframes(b"\x00\x00" * 2205)

    result = audio_analysis.analyze_audio(str(source), waveform_points=16, spectrogram_columns=24, spectrogram_bins=8)

    assert "waveformPeaks" not in result
    assert "spectrogram" not in result
    assert "binaryPayloadPath" in result
    try:
        payload = audio_analysis.read_analysis_ksbin(result["binaryPayloadPath"])
    finally:
        Path(result["binaryPayloadPath"]).unlink()

    assert len(payload["waveformPeaks"]) == 16
    assert payload["spectrogram"]["columns"] == 24
    assert payload["spectrogram"]["bins"] == 8
    assert len(payload["spectrogram"]["values"]) == 24 * 8

