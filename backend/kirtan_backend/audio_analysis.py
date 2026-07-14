from __future__ import annotations

import json
import math
import os
import struct
import subprocess
import tempfile
from pathlib import Path

import numpy as np


KSBIN_VERSION = 1
_KSBIN_HEADER = struct.Struct("<BIII")
_KSBIN_HEADER_SIZE = _KSBIN_HEADER.size


def write_analysis_ksbin(waveform: list[float], spectrogram: list[float], columns: int, bins: int) -> str:
    waveform_array = np.asarray(waveform, dtype=np.float32)
    spectrogram_array = np.asarray(spectrogram, dtype=np.float32)
    fd, path = tempfile.mkstemp(suffix=".ksbin", prefix="kirtan-preview-")
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(_KSBIN_HEADER.pack(KSBIN_VERSION, waveform_array.size, int(columns), int(bins)))
            handle.write(waveform_array.tobytes())
            handle.write(spectrogram_array.tobytes())
    except BaseException:
        try:
            os.remove(path)
        except OSError:
            pass
        raise
    return path


def read_analysis_ksbin(path: str) -> dict:
    with open(path, "rb") as handle:
        header = handle.read(_KSBIN_HEADER_SIZE)
        if len(header) < _KSBIN_HEADER_SIZE:
            raise ValueError("ksbin payload is truncated")
        version, waveform_count, columns, bins = _KSBIN_HEADER.unpack(header)
        if version != KSBIN_VERSION:
            raise ValueError(f"Unsupported ksbin version: {version}")
        waveform_bytes = handle.read(int(waveform_count) * 4)
        spectrogram_bytes = handle.read(int(columns) * int(bins) * 4)
    waveform = np.frombuffer(waveform_bytes, dtype=np.float32).astype(np.float64).tolist()
    spectrogram = np.frombuffer(spectrogram_bytes, dtype=np.float32).astype(np.float64).tolist()
    return {
        "version": version,
        "waveformPeaks": waveform,
        "spectrogram": {"columns": columns, "bins": bins, "values": spectrogram},
    }


def analyze_audio(
    path: str,
    waveform_points: int = 8192,
    spectrogram_columns: int = 8192,
    spectrogram_bins: int = 224,
    binary_payload: bool = True,
) -> dict:
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

    result: dict = {
        "path": str(audio_path),
        "filename": audio_path.name,
        "durationSeconds": round(info["durationSeconds"], 3),
        "channels": info["channels"],
        "sampleRate": info["sampleRate"],
        "bitDepth": info["bitDepth"],
        "peakDb": round(peak_db, 2),
        "clipped": peak_db >= -0.1,
    }
    if binary_payload:
        result["binaryPayloadPath"] = write_analysis_ksbin(waveform, spectrogram, spectrogram_columns, spectrogram_bins)
    else:
        result["waveformPeaks"] = waveform
        result["spectrogram"] = {
            "columns": spectrogram_columns,
            "bins": spectrogram_bins,
            # values are row-major, bin rows: values[bin * columns + column].
            "values": spectrogram,
        }
    result.update(separation_metadata)
    return result


def analyze_audio_progressive(
    path: str,
    waveform_points: int = 8192,
    spectrogram_columns: int = 8192,
    spectrogram_bins: int = 224,
    emit=None,
) -> dict:
    """Stream a preview in phases so the UI can paint before the HQ spectrogram is ready.

    Emits (via ``emit(stage, message, progress, result)``) in order:
      waveform_preview  -> fast metadata + coarse waveform (no spectrogram)
      waveform_full     -> binary ksbin with the full-resolution waveform
      spectrogram_chunk -> N column-chunks of the spectrogram as binary ksbin
    and finally returns the complete result dict (metadata + full ksbin path),
    matching the one-shot K4 payload so the client can fill ``AudioAnalysis``.
    """
    audio_path = Path(path).expanduser()
    if not audio_path.exists():
        raise FileNotFoundError(f"Audio file does not exist: {audio_path}")

    info = _ffprobe_audio_info(audio_path)
    separation_metadata = _kirtan_splitter_metadata(info.get("tags") or {})
    preview_sample_rate = 22050
    preview_samples = _decode_mono_float(audio_path, sample_rate=preview_sample_rate)
    peak_db = _peak_db_from_samples(preview_samples)

    base_meta = {
        "path": str(audio_path),
        "filename": audio_path.name,
        "durationSeconds": round(info["durationSeconds"], 3),
        "channels": info["channels"],
        "sampleRate": info["sampleRate"],
        "bitDepth": info["bitDepth"],
        "peakDb": round(peak_db, 2),
        "clipped": peak_db >= -0.1,
    }

    preview_points = 512
    preview_waveform = _waveform_peaks(preview_samples, preview_points)
    if emit is not None:
        emit(
            "waveform_preview",
            "Preview waveform",
            0.05,
            {
                "phase": "waveform_preview",
                **base_meta,
                "waveformPeaks": preview_waveform,
            },
        )

    full_waveform = _waveform_peaks(preview_samples, waveform_points)
    if emit is not None:
        wave_path = write_analysis_ksbin(full_waveform, [], 0, 0)
        emit(
            "waveform_full",
            "Full waveform",
            0.25,
            {
                "phase": "waveform_full",
                "binaryPayloadPath": wave_path,
                "waveformPointCount": len(full_waveform),
            },
        )

    spectrogram = _spectrogram(preview_samples, spectrogram_columns, spectrogram_bins, sample_rate=preview_sample_rate)

    total_chunks = 8
    chunk_size = max(1, (spectrogram_columns + total_chunks - 1) // total_chunks)
    matrix = np.asarray(spectrogram, dtype=np.float32).reshape(spectrogram_bins, spectrogram_columns)
    for idx in range(total_chunks):
        start = idx * chunk_size
        if start >= spectrogram_columns:
            break
        end = min(spectrogram_columns, start + chunk_size)
        count = end - start
        chunk_values = matrix[:, start:end].reshape(-1).tolist()
        chunk_path = write_analysis_ksbin([], chunk_values, count, spectrogram_bins)
        if emit is not None:
            emit(
                "spectrogram_chunk",
                f"Spectrogram {idx + 1}/{total_chunks}",
                0.3 + 0.6 * (idx + 1) / total_chunks,
                {
                    "phase": "spectrogram_chunk",
                    "chunkIndex": idx,
                    "totalChunks": total_chunks,
                    "columnsStart": start,
                    "columnsCount": count,
                    "totalColumns": spectrogram_columns,
                    "bins": spectrogram_bins,
                    "binaryPayloadPath": chunk_path,
                },
            )

    full_path = write_analysis_ksbin(full_waveform, spectrogram, spectrogram_columns, spectrogram_bins)
    result = {
        **base_meta,
        "phase": "complete",
        "binaryPayloadPath": full_path,
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
    frame_length = _next_power_of_two(int(min(16384, max(2048, samples_per_column * 2))))
    half_window = frame_length // 2
    window = np.hanning(frame_length).astype(np.float32)
    padded = np.pad(samples, (half_window, half_window), mode="constant")
    centers = np.linspace(0, samples.size - 1, columns)
    
    # Mel-spaced target frequencies for human-like auditory frequency resolution (iZotope RX style)
    f_min = 20.0
    f_max = sample_rate / 2.0
    mel_min = 2595.0 * np.log10(1.0 + f_min / 700.0)
    mel_max = 2595.0 * np.log10(1.0 + f_max / 700.0)
    mels = np.linspace(mel_min, mel_max, bins, dtype=np.float32)
    target_frequencies = 700.0 * (10.0 ** (mels / 2595.0) - 1.0)
    
    # Compute boundary frequencies for max-pooling
    boundaries = np.zeros(bins + 1, dtype=np.float32)
    boundaries[0] = max(0.0, target_frequencies[0] - (target_frequencies[1] - target_frequencies[0]) / 2)
    for i in range(1, bins):
        boundaries[i] = (target_frequencies[i-1] + target_frequencies[i]) / 2.0
    boundaries[bins] = target_frequencies[bins-1] + (target_frequencies[bins-1] - target_frequencies[bins-2]) / 2.0
    
    boundary_indices = boundaries / sample_rate * frame_length
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
        left_int = np.clip(np.ceil(boundary_indices[:-1]).astype(np.int64), 0, max_bin)
        right_int = np.clip(np.floor(boundary_indices[1:]).astype(np.int64), 0, max_bin)
        left_clip = np.clip(left_bins, 0, max_bin)
        right_clip = np.clip(right_bins, 0, max_bin)

        for b in range(bins):
            l_idx = left_int[b]
            r_idx = right_int[b]
            if l_idx <= r_idx:
                matrix[chunk_start:chunk_end, b] = np.max(spectrum[:, l_idx:r_idx+1], axis=1)
            else:
                lc = left_clip[b]
                rc = right_clip[b]
                matrix[chunk_start:chunk_end, b] = spectrum[:, lc] + (spectrum[:, rc] - spectrum[:, lc]) * bin_mix[b]

    if np.max(matrix) <= 0:
        return [0.0] * (columns * bins)

    matrix = matrix / (frame_length / 2.0)
    matrix = 20.0 * np.log10(np.maximum(matrix, 1e-8))
    # Row-major, bin rows: values[bin * columns + column]. See docstring.
    return [round(float(value), 4) for value in matrix.T.reshape(-1)]


def _next_power_of_two(value: int) -> int:
    return 1 << max(1, int(value) - 1).bit_length()


def _spectrogram_chunk_columns(columns: int, frame_length: int, target_frame_bytes: int = 64 * 1024 * 1024) -> int:
    bytes_per_frame = max(1, frame_length) * np.dtype(np.float32).itemsize
    by_memory = max(1, target_frame_bytes // bytes_per_frame)
    return max(1, min(int(columns), int(by_memory)))
