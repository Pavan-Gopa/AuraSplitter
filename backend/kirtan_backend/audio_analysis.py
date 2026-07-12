from __future__ import annotations

import json
import math
import subprocess
from pathlib import Path

import numpy as np


def analyze_audio(path: str, waveform_points: int = 8192, spectrogram_columns: int = 8192, spectrogram_bins: int = 224) -> dict:
    audio_path = Path(path).expanduser()
    if not audio_path.exists():
        raise FileNotFoundError(f"Audio file does not exist: {audio_path}")

    info = _ffprobe_audio_info(audio_path)
    separation_metadata = _kirtan_splitter_metadata(info.get("tags") or {})
    preview_sample_rate = 22050
    preview_samples = _decode_mono_float(audio_path, sample_rate=preview_sample_rate)
    peak_db = _peak_db_from_samples(preview_samples)
    waveform = _waveform_peaks(preview_samples, waveform_points)
    spectrogram = _spectrogram(preview_samples, spectrogram_columns, spectrogram_bins, sample_rate=preview_sample_rate)

    result = {
        "path": str(audio_path),
        "filename": audio_path.name,
        "durationSeconds": round(info["durationSeconds"], 3),
        "channels": info["channels"],
        "sampleRate": info["sampleRate"],
        "bitDepth": info["bitDepth"],
        "peakDb": round(peak_db, 2),
        "clipped": peak_db >= -0.1,
        "waveformPeaks": waveform,
        "spectrogram": {
            "columns": spectrogram_columns,
            "bins": spectrogram_bins,
            # values are row-major, bin rows: values[bin * columns + column].
            "values": spectrogram,
        },
    }
    result.update(separation_metadata)
    return result


def _ffprobe_audio_info(path: Path) -> dict:
    output = subprocess.check_output(
        [
            "ffprobe",
            "-v",
            "error",
            "-select_streams",
            "a:0",
            "-show_entries",
            "stream=channels,sample_rate,duration,bits_per_raw_sample,bits_per_sample,sample_fmt:format=duration:format_tags",
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
        "bitDepth": _bit_depth_from_stream(stream),
        "durationSeconds": float(duration or 0),
        "tags": fmt.get("tags") or {},
    }


def _bit_depth_from_stream(stream: dict) -> int | None:
    value = stream.get("bits_per_raw_sample") or stream.get("bits_per_sample")
    if value and str(value).isdigit():
        depth = int(value)
        return depth if depth > 0 else None
    sample_format = str(stream.get("sample_fmt") or "").lower().rstrip("p")
    if sample_format in {"u8", "s8"}:
        return 8
    if sample_format in {"s16", "u16"}:
        return 16
    if sample_format in {"s24", "u24"}:
        return 24
    if sample_format in {"s32", "u32", "flt"}:
        return 32
    if sample_format == "dbl":
        return 64
    return None


def _kirtan_splitter_metadata(tags: dict) -> dict:
    comment = str(tags.get("comment") or tags.get("COMMENT") or "")
    encoded_by = str(tags.get("encoded_by") or tags.get("ENCODED_BY") or "")
    if not comment.startswith("KirtanSplitter") and encoded_by != "KirtanSplitter":
        return {}

    parsed = {}
    body = comment.removeprefix("KirtanSplitter").strip()
    for part in body.split(";"):
        key, separator, value = part.strip().partition("=")
        if separator:
            parsed[key.strip()] = value.strip()

    result = {}
    if parsed.get("model"):
        result["separationModelName"] = parsed["model"]
    if parsed.get("checkpoint"):
        result["separationModelCheckpoint"] = parsed["checkpoint"]
    if parsed.get("preset"):
        result["separationPresetID"] = parsed["preset"]
    if parsed.get("process"):
        result["separationProcessPresetTitle"] = parsed["process"]
    return result


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


def _peak_db_from_samples(samples: np.ndarray) -> float:
    samples = np.asarray(samples, dtype=np.float32)
    if samples.size == 0:
        return -120.0
    samples = np.nan_to_num(samples, nan=0.0, posinf=0.0, neginf=0.0)
    peak = float(np.max(np.abs(samples)))
    if peak <= 1e-8:
        return -120.0
    value = 20.0 * math.log10(peak)
    if not math.isfinite(value):
        return -120.0
    return round(max(-120.0, min(24.0, value)), 2)


def _spectrogram(samples: np.ndarray, columns: int, bins: int, sample_rate: int = 22050) -> list[float]:
    """Compute a normalized log-magnitude spectrogram.

    Returns a flat ``list[float]`` laid out **row-major with bin rows**:
    ``values[bin * columns + column]`` for ``bin in 0..bins``, ``column in
    0..columns``. This matches the row-major layout a Metal texture expects
    (``width=columns``, ``height=bins``), so the client can upload it without
    a CPU transpose.
    """
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
    left_bins = np.floor(spectrum_positions).astype(np.int64)
    right_bins = left_bins + 1
    bin_mix = (spectrum_positions - left_bins).astype(np.float32)
    matrix = np.zeros((columns, bins), dtype=np.float32)
    chunk_columns = _spectrogram_chunk_columns(columns=columns, frame_length=frame_length)

    for chunk_start in range(0, columns, chunk_columns):
        chunk_end = min(columns, chunk_start + chunk_columns)
        chunk_centers = centers[chunk_start:chunk_end]
        frames = np.empty((chunk_end - chunk_start, frame_length), dtype=np.float32)
        for local_index, center_value in enumerate(chunk_centers):
            center = int(round(float(center_value))) + half_window
            start = center - half_window
            frames[local_index] = padded[start:start + frame_length]
        frames *= window

        spectrum = np.abs(np.fft.rfft(frames, axis=1)).astype(np.float32, copy=False)
        if spectrum.shape[1] <= 2:
            continue

        max_bin = spectrum.shape[1] - 1
        left = np.clip(left_bins, 0, max_bin)
        right = np.clip(right_bins, 0, max_bin)
        lower = spectrum[:, left]
        upper = spectrum[:, right]
        matrix[chunk_start:chunk_end] = lower + (upper - lower) * bin_mix

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
    # Row-major, bin rows: values[bin * columns + column]. See docstring.
    return [round(float(value), 4) for value in matrix.T.reshape(-1)]


def _next_power_of_two(value: int) -> int:
    return 1 << max(1, int(value) - 1).bit_length()


def _spectrogram_chunk_columns(columns: int, frame_length: int, target_frame_bytes: int = 64 * 1024 * 1024) -> int:
    bytes_per_frame = max(1, frame_length) * np.dtype(np.float32).itemsize
    by_memory = max(1, target_frame_bytes // bytes_per_frame)
    return max(1, min(int(columns), int(by_memory)))
