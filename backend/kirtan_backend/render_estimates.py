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


def _usage_counts_by_field(model_dir: str, field: str) -> dict[str, int]:
    counts: dict[str, int] = {}
    for sample in load_render_benchmarks(model_dir):
        key = str(sample.get(field) or "").strip()
        if not key:
            continue
        counts[key] = counts.get(key, 0) + 1
    return counts


def model_usage_counts(model_dir: str) -> dict[str, int]:
    """Completed-run counts keyed by model filename (Models sidebar groups)."""
    return _usage_counts_by_field(model_dir, "modelFilename")


def preset_usage_counts(model_dir: str) -> dict[str, int]:
    """Completed-run counts keyed by modelPresetID so chain presets that reuse
    a base preset's checkpoint report their own usage."""
    return _usage_counts_by_field(model_dir, "modelPresetID")


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

    raw_settings = dict(sample.get("settings") or {})
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
        "settings": raw_settings,
        # Knobs captured directly so estimates can match on the real process
        # settings, not only on processPresetID. Prefer an explicit top-level
        # value, then fall back to the settings dict written at run time.
        "segmentSize": _positive_int(sample.get("segmentSize", raw_settings.get("mdxcSegmentSize"))),
        "overlap": _positive_int(sample.get("overlap", raw_settings.get("mdxcOverlap"))),
        "batchSize": _positive_int(sample.get("batchSize", raw_settings.get("mdxcBatchSize"))),
        "chunkDuration": _positive_float(sample.get("chunkDuration", raw_settings.get("chunkDuration"))),
        "speedMode": str(sample.get("speedMode", raw_settings.get("speedMode")) or ""),
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
    process_preset_id: str | None = None,
    audio_duration_seconds: float,
    gpu_core_count: int | None = None,
    mdxc_segment_size: int | None = None,
    mdxc_batch_size: int | None = None,
    mdxc_overlap: int | None = None,
    chunk_duration: float | None = None,
    speed_mode: str | None = None,
) -> dict[str, Any]:
    duration_seconds = _positive_float(audio_duration_seconds)
    process_preset_id = process_preset_id or ""
    if duration_seconds is None:
        return _unavailable(
            model_filename=model_filename,
            process_preset_id=process_preset_id,
            reason="missing_duration",
        )

    samples = [
        sample
        for sample in load_render_benchmarks(model_dir)
        if sample.get("modelFilename") == model_filename
        and _positive_float(sample.get("secondsPerAudioSecond")) is not None
    ]
    if not samples:
        return _unavailable(
            model_filename=model_filename,
            process_preset_id=process_preset_id,
            reason="no_calibration",
            audio_duration_seconds=duration_seconds,
        )

    target_gpu_cores = _positive_int(gpu_core_count)

    # Knobs the client actually supplied. Only these participate in exact
    # matching — a knob the caller didn't send is simply left unconstrained.
    requested = {
        "segmentSize": _positive_int(mdxc_segment_size),
        "overlap": _positive_int(mdxc_overlap),
        "batchSize": _positive_int(mdxc_batch_size),
        "chunkDuration": _positive_float(chunk_duration),
        "speedMode": str(speed_mode or "").strip(),
    }
    requested_knobs = {k: v for k, v in requested.items() if v not in (None, "")}

    def sample_knobs(sample: dict[str, Any]) -> dict[str, Any]:
        return {
            "segmentSize": _positive_int(sample.get("segmentSize")),
            "overlap": _positive_int(sample.get("overlap")),
            "batchSize": _positive_int(sample.get("batchSize")),
            "chunkDuration": _positive_float(sample.get("chunkDuration")),
            "speedMode": str(sample.get("speedMode") or "").strip(),
        }

    if requested_knobs:
        # Primary: exact match on every supplied knob. processPresetID is now a
        # soft signal only (kept for continuity) and does NOT gate the match,
        # so changing Segment / Batch / Overlap / Chunk / Speed changes the Est.
        def exact_match(sample: dict[str, Any]) -> bool:
            sk = sample_knobs(sample)
            return all(sk[k] == v for k, v in requested_knobs.items())

        primary = [s for s in samples if exact_match(s)]
        method = "exact"
    else:
        # No explicit knobs: fall back to the legacy processPresetID match so
        # pre-knob benchmarks and callers that still send only a preset work.
        primary = [s for s in samples if (s.get("processPresetID") or "") == process_preset_id]

    if primary:
        return _build_estimate(
            primary,
            duration_seconds,
            target_gpu_cores,
            "exact",
            model_filename,
            process_preset_id,
        )

    # Fallback: no exact knob match. Use the nearest same-model samples with a
    # conservative scaling heuristic — each sample's measured seconds-per-audio-
    # second is scaled by a cost ratio (requested knob cost / recorded knob
    # cost). We never invent numbers from thin air; the ratio is clamped so we
    # bias toward the slower (conservative) side when we have no exact match.
    predictions: list[float] = []
    baseline_gpu_cores: list[int] = []
    for sample in samples:
        ratio = _positive_float(sample.get("secondsPerAudioSecond"))
        if ratio is None:
            continue
        scale = _conservative_knob_scale(requested, sample_knobs(sample))
        sample_gpu_cores = _positive_int(sample.get("gpuCoreCount"))
        gpu_scale = 1.0
        if target_gpu_cores and sample_gpu_cores:
            gpu_scale = sample_gpu_cores / target_gpu_cores
            baseline_gpu_cores.append(sample_gpu_cores)
        predictions.append(duration_seconds * ratio * scale * gpu_scale)

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
        "method": "heuristic",
        "modelFilename": model_filename,
        "processPresetID": process_preset_id,
        "estimatedSeconds": estimate_seconds,
        "audioDurationSeconds": round(duration_seconds, 3),
        "sampleCount": len(predictions),
        "baselineGpuCoreCount": int(statistics.median(baseline_gpu_cores)) if baseline_gpu_cores else None,
        "targetGpuCoreCount": target_gpu_cores,
        "secondsPerAudioSecond": round(estimate_seconds / duration_seconds, 6),
    }


def _build_estimate(
    matched: list[dict[str, Any]],
    duration_seconds: float,
    target_gpu_cores: int | None,
    method: str,
    model_filename: str,
    process_preset_id: str,
) -> dict[str, Any]:
    predictions: list[float] = []
    baseline_gpu_cores: list[int] = []
    for sample in matched:
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
        "method": method,
        "modelFilename": model_filename,
        "processPresetID": process_preset_id,
        "estimatedSeconds": estimate_seconds,
        "audioDurationSeconds": round(duration_seconds, 3),
        "sampleCount": len(predictions),
        "baselineGpuCoreCount": int(statistics.median(baseline_gpu_cores)) if baseline_gpu_cores else None,
        "targetGpuCoreCount": target_gpu_cores,
        "secondsPerAudioSecond": round(estimate_seconds / duration_seconds, 6),
    }


def _knob_cost(knobs: dict[str, Any]) -> float:
    """Rough relative wall-time cost of a knob set.

    Bigger segment / overlap = more compute per pass (slower); bigger batch =
    more parallelism (faster); chunked processing reduces peak overhead (a bit
    faster); latency_safe_* speed modes force batch=1 and extra normalisation
    (slower). This is intentionally a coarse model — it is only ever used to
    scale real measured samples when no exact knob match exists, never to invent
    numbers from scratch.
    """
    segment = knobs.get("segmentSize") or 256
    overlap = knobs.get("overlap") or 8
    batch = knobs.get("batchSize") or 1
    chunk = knobs.get("chunkDuration")
    speed = str(knobs.get("speedMode") or "").lower()

    cost = (segment / 256.0) * (max(float(overlap), 1.0) / 8.0) / (max(float(batch), 1.0) / 1.0)
    if chunk and float(chunk) > 0:
        cost *= 0.9  # chunked processing amortises overhead
    if "latency" in speed:
        cost *= 1.0  # baseline, slowest common mode
    elif "fast" in speed or "turbo" in speed:
        cost *= 0.85
    return cost


def _conservative_knob_scale(requested: dict[str, Any], sample_knobs: dict[str, Any]) -> float:
    """Scale a recorded sample's rate toward the requested knobs, clamped.

    Missing requested knobs are treated as equal to the sample (ratio 1.0) so we
    never optimistically assume an unseen knob is free. The clamp keeps the
    prediction within [0.5, 3.0] of the nearest real sample — conservative.
    """
    req_cost = _knob_cost(requested)
    sample_cost = _knob_cost(sample_knobs)
    if sample_cost <= 0:
        return 1.0
    scale = req_cost / sample_cost
    return min(3.0, max(0.5, scale))


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
