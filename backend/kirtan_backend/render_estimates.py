from __future__ import annotations

import json
import statistics
import time
from pathlib import Path
from typing import Any

BENCHMARKS_FILENAME = "render_benchmarks.json"
MAX_SAMPLES = 1000


def render_benchmark_path(model_dir: str) -> Path:
    return Path(model_dir).expanduser() / BENCHMARKS_FILENAME


def load_render_benchmarks(model_dir: str) -> list[dict[str, Any]]:
    path = render_benchmark_path(model_dir)
    if not path.is_file():
        return []
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []
    if not isinstance(data, list):
        return []
    return [sample for sample in data if isinstance(sample, dict)]


def record_render_benchmark(model_dir: str, sample: dict[str, Any]) -> dict[str, Any]:
    elapsed_seconds = _positive_float(sample.get("elapsedSeconds"))
    duration_seconds = _positive_float(sample.get("audioDurationSeconds"))
    model_filename = str(sample.get("modelFilename") or "").strip()
    process_preset_id = str(sample.get("processPresetID") or "builtin.default").strip()
    if not model_filename:
        raise ValueError("Missing modelFilename")
    if elapsed_seconds is None:
        raise ValueError("elapsedSeconds must be positive")
    if duration_seconds is None:
        raise ValueError("audioDurationSeconds must be positive")

    recorded = {
        "timestamp": float(sample.get("timestamp") or time.time()),
        "modelFilename": model_filename,
        "modelPresetID": str(sample.get("modelPresetID") or ""),
        "processPresetID": process_preset_id,
        "processPresetTitle": str(sample.get("processPresetTitle") or process_preset_id),
        "elapsedSeconds": round(elapsed_seconds, 3),
        "audioDurationSeconds": round(duration_seconds, 3),
        "secondsPerAudioSecond": round(elapsed_seconds / duration_seconds, 6),
        "gpuCoreCount": _positive_int(sample.get("gpuCoreCount")),
        "settings": dict(sample.get("settings") or {}),
    }

    path = render_benchmark_path(model_dir)
    path.parent.mkdir(parents=True, exist_ok=True)
    samples = load_render_benchmarks(model_dir)
    samples.append(recorded)
    samples = samples[-MAX_SAMPLES:]
    path.write_text(json.dumps(samples, ensure_ascii=False, indent=2), encoding="utf-8")
    return recorded


def estimate_render_time(
    model_dir: str,
    *,
    model_filename: str,
    process_preset_id: str,
    audio_duration_seconds: float,
    gpu_core_count: int | None = None,
) -> dict[str, Any]:
    duration_seconds = _positive_float(audio_duration_seconds)
    if duration_seconds is None:
        return _unavailable(
            model_filename=model_filename,
            process_preset_id=process_preset_id,
            reason="missing_duration",
        )

    matching_samples = [
        sample
        for sample in load_render_benchmarks(model_dir)
        if sample.get("modelFilename") == model_filename
        and sample.get("processPresetID") == process_preset_id
        and _positive_float(sample.get("secondsPerAudioSecond")) is not None
    ]
    if not matching_samples:
        return _unavailable(
            model_filename=model_filename,
            process_preset_id=process_preset_id,
            reason="no_calibration",
            audio_duration_seconds=duration_seconds,
        )

    target_gpu_cores = _positive_int(gpu_core_count)
    predictions: list[float] = []
    baseline_gpu_cores: list[int] = []
    for sample in matching_samples:
        ratio = _positive_float(sample.get("secondsPerAudioSecond"))
        if ratio is None:
            continue
        sample_gpu_cores = _positive_int(sample.get("gpuCoreCount"))
        gpu_scale = 1.0
        if target_gpu_cores and sample_gpu_cores:
            gpu_scale = sample_gpu_cores / target_gpu_cores
            baseline_gpu_cores.append(sample_gpu_cores)
        predictions.append(duration_seconds * ratio * gpu_scale)

    if not predictions:
        return _unavailable(
            model_filename=model_filename,
            process_preset_id=process_preset_id,
            reason="no_valid_samples",
            audio_duration_seconds=duration_seconds,
        )

    estimate_seconds = round(float(statistics.median(predictions)), 1)
    return {
        "status": "calibrated",
        "reason": None,
        "modelFilename": model_filename,
        "processPresetID": process_preset_id,
        "estimatedSeconds": estimate_seconds,
        "audioDurationSeconds": round(duration_seconds, 3),
        "sampleCount": len(predictions),
        "baselineGpuCoreCount": int(statistics.median(baseline_gpu_cores)) if baseline_gpu_cores else None,
        "targetGpuCoreCount": target_gpu_cores,
        "secondsPerAudioSecond": round(estimate_seconds / duration_seconds, 6),
    }


def _unavailable(
    *,
    model_filename: str,
    process_preset_id: str,
    reason: str,
    audio_duration_seconds: float | None = None,
) -> dict[str, Any]:
    return {
        "status": "unavailable",
        "reason": reason,
        "modelFilename": model_filename,
        "processPresetID": process_preset_id,
        "estimatedSeconds": None,
        "audioDurationSeconds": audio_duration_seconds,
        "sampleCount": 0,
        "baselineGpuCoreCount": None,
        "targetGpuCoreCount": None,
        "secondsPerAudioSecond": None,
    }


def _positive_float(value) -> float | None:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if number > 0 else None


def _positive_int(value) -> int | None:
    try:
        number = int(value)
    except (TypeError, ValueError):
        return None
    return number if number > 0 else None
