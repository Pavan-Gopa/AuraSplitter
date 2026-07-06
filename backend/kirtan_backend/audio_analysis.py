from __future__ import annotations

import json
import math
import re
import subprocess
from pathlib import Path

import numpy as np


def analyze_audio(path: str, waveform_points: int = 8192, spectrogram_columns: int = 8192, spectrogram_bins: int = 224) -> dict:
    audio_path = Path(path).expanduser()
    if not audio_path.exists():
        raise FileNotFoundError(f"Audio file does not exist: {audio_path}")

    info = _ffprobe_audio_info(audio_path)
    peak_db = _ffmpeg_peak_db(audio_path)
    preview_sample_rate = 22050
    preview_samples = _decode_mono_float(audio_path, sample_rate=preview_sample_rate)
    waveform = _waveform_peaks(preview_samples, waveform_points)
    spectrogram = _spectrogram(preview_samples, spectrogram_columns, spectrogram_bins, sample_rate=preview_sample_rate)

    return {
        "path": str(audio_path),
        "filename": audio_path.name,
        "durationSeconds": round(info["durationSeconds"], 3),
        "channels": info["channels"],
        "sampleRate": info["sampleRate"],
        "peakDb": round(peak_db, 2),
        "clipped": peak_db >= -0.1,
        "waveformPeaks": waveform,
        "spectrogram": {
            "columns": spectrogram_columns,
            "bins": spectrogram_bins,
            "values": spectrogram,
        },
    }


def _ffprobe_audio_info(path: Path) -> dict:
    output = subprocess.check_output(
        [
            "ffprobe",
            "-v",
            "error",
            "-select_streams",
            "a:0",
            "-show_entries",
            "stream=channels,sample_rate,duration",
            "-show_entries",
            "format=duration",
            "-of",
            "json",
            str(path),
        ],
        text=True,
        timeout=20,
    )
    payload = json.loads(output)
    stream = (payload.get("streams") or [{}])[0]
    fmt = payload.get("format") or {}
    duration = stream.get("duration") or fmt.get("duration") or 0
    return {
        "channels": int(stream.get("channels") or 0),
        "sampleRate": int(stream.get("sample_rate") or 0),
        "durationSeconds": float(duration or 0),
    }


def _ffmpeg_peak_db(path: Path) -> float:
    try:
        output = subprocess.check_output(
            [
                "ffmpeg",
                "-hide_banner",
                "-nostats",
                "-i",
                str(path),
                "-af",
                "volumedetect",
                "-f",
                "null",
                "-",
            ],
            text=True,
            stderr=subprocess.STDOUT,
            timeout=60,
        )
    except subprocess.CalledProcessError as exc:
        output = exc.output or ""
    match = re.search(r"max_volume:\s+(-?[0-9.]+)\s+dB", output)
    if not match:
        return -120.0
    value = float(match.group(1))
    if not math.isfinite(value):
        return -120.0
    return max(-120.0, min(24.0, value))


def _decode_mono_float(path: Path, sample_rate: int) -> np.ndarray:
    output = subprocess.check_output(
        [
            "ffmpeg",
            "-hide_banner",
            "-loglevel",
            "error",
            "-i",
            str(path),
            "-vn",
            "-ac",
            "1",
            "-ar",
            str(sample_rate),
            "-f",
            "f32le",
            "pipe:1",
        ],
        timeout=90,
    )
    samples = np.frombuffer(output, dtype=np.float32)
    if samples.size == 0:
        return np.zeros(1, dtype=np.float32)
    return np.nan_to_num(samples, nan=0.0, posinf=0.0, neginf=0.0)


def _waveform_peaks(samples: np.ndarray, points: int) -> list[float]:
    points = max(1, int(points))
    if samples.size == 0:
        return [0.0] * points
    edges = np.linspace(0, samples.size, points + 1, dtype=np.int64)
    peaks = []
    for idx in range(points):
        start, end = int(edges[idx]), int(edges[idx + 1])
        segment = samples[start:end]
        peak = float(np.max(np.abs(segment))) if segment.size else 0.0
        peaks.append(round(min(1.0, peak), 4))
    return peaks


def _spectrogram(samples: np.ndarray, columns: int, bins: int, sample_rate: int = 22050) -> list[float]:
    columns = max(1, int(columns))
    bins = max(1, int(bins))
    if samples.size == 0:
        return [0.0] * (columns * bins)

    samples = np.asarray(samples, dtype=np.float32)
    samples = np.nan_to_num(samples, nan=0.0, posinf=0.0, neginf=0.0)
    if np.max(np.abs(samples)) <= 1e-8:
        return [0.0] * (columns * bins)

    samples_per_column = max(1.0, samples.size / columns)
    frame_length = _next_power_of_two(int(min(16384, max(512, samples_per_column * 2))))
    half_window = frame_length // 2
    window = np.hanning(frame_length).astype(np.float32)
    padded = np.pad(samples, (half_window, half_window), mode="constant")
    centers = np.linspace(0, samples.size - 1, columns)
    target_frequencies = np.linspace(sample_rate / (2 * bins), sample_rate / 2, bins, dtype=np.float32)
    spectrum_positions = target_frequencies / sample_rate * frame_length
    matrix = np.zeros((columns, bins), dtype=np.float32)

    for col in range(columns):
        center = int(round(float(centers[col]))) + half_window
        start = center - half_window
        segment = padded[start:start + frame_length]
        if segment.size != frame_length:
            continue

        spectrum = np.abs(np.fft.rfft(segment * window)).astype(np.float32)
        if spectrum.size <= 2:
            continue

        matrix[col] = np.interp(
            spectrum_positions,
            np.arange(spectrum.size, dtype=np.float32),
            spectrum,
            left=0.0,
            right=0.0,
        ).astype(np.float32)

    if np.max(matrix) <= 0:
        return [0.0] * (columns * bins)

    matrix = 20.0 * np.log10(np.maximum(matrix, 1e-8))
    finite_values = matrix[np.isfinite(matrix)]
    if finite_values.size == 0:
        return [0.0] * (columns * bins)

    floor = float(np.percentile(finite_values, 35))
    ceiling = float(np.percentile(finite_values, 99.7))
    if ceiling <= floor:
        ceiling = floor + 1.0
    matrix = (matrix - floor) / (ceiling - floor)
    matrix = np.clip(matrix, 0, 1)
    matrix = np.power(matrix, 0.72)
    return [round(float(value), 4) for value in matrix.reshape(-1)]


def _next_power_of_two(value: int) -> int:
    return 1 << max(1, int(value) - 1).bit_length()
