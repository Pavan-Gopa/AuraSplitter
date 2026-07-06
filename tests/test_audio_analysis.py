import numpy as np

from kirtan_backend import audio_analysis
from kirtan_backend.audio_analysis import _spectrogram


def _sine(frequency: float, sample_rate: int = 22_050, seconds: float = 1.0) -> np.ndarray:
    t = np.arange(int(sample_rate * seconds), dtype=np.float32) / sample_rate
    return np.sin(2 * np.pi * frequency * t).astype(np.float32)


def _dominant_bin(values: list[float], columns: int, bins: int) -> int:
    matrix = np.array(values, dtype=np.float32).reshape(columns, bins)
    return int(np.argmax(matrix.mean(axis=0)))


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
