from __future__ import annotations

import json
import logging
import math
import os
import re
import subprocess
import tempfile
import threading
import time
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from .audio_analysis import analyze_audio, analyze_audio_progressive, _bit_depth_from_stream
from .ffmpeg_tools import ffmpeg_bin, ffprobe_bin
from .jobs import SeparationJob
from .model_catalog import (
    attach_model_pack_to_separator,
    display_name_for_model,
    ensure_model_pack_assets,
    get_model_pack_entry,
    metadata_for_model_stem,
)
from .onnx_backend import onnx_runtime_status
from .render_estimates import estimate_render_time, record_render_benchmark
from .runtime import delete_model_cache_item, delete_model_group_source, model_cache, runtime_stats
from .presets import preset_list

ProgressCallback = Callable[[str, str, float, dict | None], None]

HEARTBEAT_EXPECTED_STAGE_SECONDS = 30 * 60
# Cap below 1.0 so "complete" is reserved for real finish; do not freeze at 87%.
HEARTBEAT_FRACTION_CAP = 0.97


def _format_elapsed_duration(seconds: float) -> str:
    total_seconds = max(0, int(round(seconds)))
    hours = total_seconds // 3600
    minutes = (total_seconds % 3600) // 60
    remaining_seconds = total_seconds % 60

    if hours > 0:
        return f"{hours}h {minutes}m {remaining_seconds}s"
    if minutes > 0:
        return f"{minutes}m {remaining_seconds}s"
    return f"{remaining_seconds}s"


def _progress_message(message: str, elapsed_seconds: float) -> str:
    if elapsed_seconds < 1:
        return message
    return f"{message} - elapsed {_format_elapsed_duration(elapsed_seconds)}"


def _heartbeat_progress_value(
    start: float,
    end: float,
    elapsed_seconds: float,
    expected_seconds: float = HEARTBEAT_EXPECTED_STAGE_SECONDS,
) -> float:
    """Map elapsed time toward ``end`` using a calibrated estimate when available.

    Linear in elapsed/expected so a 40‑minute run does not freeze at ~87% while
    the timer keeps climbing (old log-curve + 0.92 cap caused that).
    """
    if end <= start:
        return end

    elapsed = max(0.0, float(elapsed_seconds))
    expected = max(30.0, float(expected_seconds or HEARTBEAT_EXPECTED_STAGE_SECONDS))
    # Soft asymptote past the estimate so overruns still creep forward slowly.
    if elapsed <= expected:
        fraction = elapsed / expected
    else:
        overrun = elapsed - expected
        fraction = 1.0 - 0.15 * math.exp(-overrun / max(60.0, expected * 0.25))
    fraction = min(HEARTBEAT_FRACTION_CAP, max(0.0, fraction))
    return start + (end - start) * fraction


def _bit_depth_from_sample_format(sample_format: str) -> int | None:
    if not sample_format:
        return None
    normalized = sample_format.lower().rstrip("p")
    if normalized in {"u8", "s8"}:
        return 8
    if normalized in {"s16", "u16"}:
        return 16
    if normalized in {"s24", "u24"}:
        return 24
    if normalized in {"s32", "u32", "flt"}:
        return 32
    if normalized == "dbl":
        return 64
    return None


@dataclass(frozen=True)
class AudioFormatSpec:
    channels: int | None
    sample_rate: int | None
    bit_depth: int | None
    codec_name: str | None


UVR_MODEL_ALIASES = {
    "model_bs_roformer_ep_317_sdr_12.9755.ckpt": "Kirtan Clean Split",
    "model_bs_roformer_ep_368_sdr_12.9628.ckpt": "Kirtan Vocal Classic",
    "mel_band_roformer_karaoke_aufr33_viperx_sdr_10.1956.ckpt": "Kirtan Karaoke Classic",
}


class BackendOperationCancelled(RuntimeError):
    pass


class MlxSeparatorEngine:
    def __init__(self, model_dir: str, logger: logging.Logger | None = None):
        self.model_dir = str(Path(model_dir).expanduser())
        self.logger = logger or logging.getLogger("kirtan_backend.engine")
        self._cancel_event = threading.Event()
        self._cancel_reason = "User cancelled current operation"
        Path(self.model_dir).mkdir(parents=True, exist_ok=True)

        # Warm Separator cache (K3): reuse the loaded Separator for the same
        # model + parameter fingerprint instead of reloading on every separate.
        self._cached_separator = None
        self._cached_model_filename = None
        self._cached_fingerprint = None

        # K8: best-effort Metal memory / cache limits at engine startup.
        try:
            from . import runtime

            self._mlx_memory_config = runtime.configure_mlx_memory()
        except Exception as exc:  # pragma: no cover - defensive
            self._mlx_memory_config = {"applied": False, "reason": f"{type(exc).__name__}: {exc}"}

    def health(self) -> dict:
        import mlx.core as mx
        import mlx_audio_separator

        return {
            "backend": "mlx-audio-separator",
            "gpu": "MLX/Metal",
            "mlxDevice": str(mx.default_device()),
            "packageVersion": getattr(mlx_audio_separator, "__version__", "unknown"),
            "modelDir": self.model_dir,
            "onnxRuntime": onnx_runtime_status(),
        }

    def list_models(self, limit: int = 500) -> list[dict]:
        from mlx_audio_separator import Separator

        separator = Separator(info_only=True, model_file_dir=self.model_dir)
        attach_model_pack_to_separator(separator)
        simplified = separator.get_simplified_model_list(filter_sort_by="filename")
        models: list[dict] = []
        for filename, info in simplified.items():
            models.append(
                {
                    "filename": filename,
                    "name": self._display_model_name(filename, info.get("Name", filename)),
                    "type": info.get("Type", "Unknown"),
                    "stems": info.get("Stems", []),
                    "sdr": info.get("SDR", {}),
                    "isDownloaded": self._is_model_downloaded(filename),
                }
            )
            if len(models) >= limit:
                break
        return models

    def list_presets(self) -> list[dict]:
        return preset_list(self.model_dir)

    def runtime_stats(self) -> dict:
        stats = runtime_stats(self.model_dir)
        stats["modelHot"] = self._cached_separator is not None
        return stats

    def model_cache(self) -> dict:
        return model_cache(self.model_dir)

    def delete_model_cache_item(self, item_path: str) -> dict:
        return delete_model_cache_item(self.model_dir, item_path)

    def delete_model_group_source(self, group_id: str) -> dict:
        return delete_model_group_source(self.model_dir, group_id)

    def analyze_audio(self, path: str, waveform_points: int = 8192, spectrogram_columns: int = 8192, spectrogram_bins: int = 224, binary_payload: bool = True) -> dict:
        return analyze_audio(path, waveform_points, spectrogram_columns, spectrogram_bins, binary_payload=binary_payload)

    def analyze_audio_progressive(self, path: str, waveform_points: int = 8192, spectrogram_columns: int = 8192, spectrogram_bins: int = 224, emit=None) -> dict:
        return analyze_audio_progressive(path, waveform_points, spectrogram_columns, spectrogram_bins, emit=emit)

    def render_estimate(self, params: dict, model_filename: str) -> dict:
        duration_seconds = params.get("durationSeconds") or params.get("duration_seconds")
        if duration_seconds in (None, "", 0, "0"):
            input_path = params.get("inputPath") or params.get("path")
            duration_seconds = self._audio_duration_seconds(Path(str(input_path)).expanduser()) if input_path else None
        process_preset_id = str(params.get("processPresetID", params.get("process_preset_id", "builtin.default")))
        gpu_core_count = params.get("gpuCoreCount", params.get("gpu_core_count"))
        if gpu_core_count in (None, "", 0, "0"):
            gpu_core_count = self._gpu_core_count()
        # Honest estimate: hand the real process knobs to the predictor so it
        # can match on segment / batch / overlap / chunk / speed, not only the
        # preset id.
        return estimate_render_time(
            self.model_dir,
            model_filename=model_filename,
            process_preset_id=process_preset_id,
            audio_duration_seconds=duration_seconds or 0,
            gpu_core_count=gpu_core_count,
            mdxc_segment_size=params.get("mdxcSegmentSize", params.get("mdxc_segment_size")),
            mdxc_batch_size=params.get("mdxcBatchSize", params.get("mdxc_batch_size")),
            mdxc_overlap=params.get("mdxcOverlap", params.get("mdxc_overlap")),
            chunk_duration=params.get("chunkDuration", params.get("chunk_duration")),
            speed_mode=params.get("speedMode", params.get("speed_mode")),
        )

    def cancel_current(self, reason: str = "User cancelled current operation") -> dict:
        self._cancel_reason = reason
        self._cancel_event.set()
        self.invalidate_model_cache(f"cancel: {reason}")
        self.logger.info("Cancellation requested: %s", reason)
        return {
            "cancelled": True,
            "reason": reason,
            "backendRestartRequired": True,
        }

    def separate(self, job: SeparationJob, progress: ProgressCallback) -> dict:
        from mlx_audio_separator import Separator

        self._cancel_event.clear()
        input_path = Path(job.input_path).expanduser()
        output_dir = Path(job.output_dir).expanduser()
        if not input_path.exists():
            raise FileNotFoundError(f"Input audio file does not exist: {input_path}")
        output_dir.mkdir(parents=True, exist_ok=True)
        source_format = self._source_audio_format(input_path)

        started = time.perf_counter()
        started_at = time.time()

        self.logger.info(
            "Starting separation input=%s output_dir=%s model=%s preset=%s "
            "output_format=%s chunk_duration=%s mdxc_segment_size=%s "
            "mdxc_overlap=%s mdxc_batch_size=%s mdxc_override_model_segment_size=%s "
            "speed_mode=%s cache_clear_policy=%s write_workers=%s "
            "source_channels=%s source_sample_rate=%s source_bit_depth=%s source_codec=%s",
            input_path,
            output_dir,
            job.model_filename,
            job.preset,
            job.output_format,
            job.chunk_duration,
            job.mdxc_segment_size,
            job.mdxc_overlap,
            job.mdxc_batch_size,
            job.mdxc_override_model_segment_size,
            job.speed_mode,
            job.cache_clear_policy,
            job.write_workers,
            source_format.channels,
            source_format.sample_rate,
            source_format.bit_depth,
            source_format.codec_name,
        )

        self._raise_if_cancelled()
        resolved_batch_size = self._resolve_mdxc_batch_size(job)
        separator, model_hot = self._get_or_load_separator(job, progress)
        # latency_safe_* speed modes force MDXC batch=1 inside mlx-audio-separator.
        # Re-assert the user's batch after Separator construction so Batch 2/4 is real.
        self._force_separator_batch_size(separator, resolved_batch_size)
        # CRITICAL: Separator is constructed with model_dir as a placeholder output.
        # Stems must go to job.output_dir (…/Song_stems). Set BOTH the wrapper and
        # model_instance — the library writes via model_instance.output_dir.
        self._set_separator_output_dir(separator, output_dir)
        source_duration = self._audio_duration_seconds(input_path)
        expected_separate = self._expected_separation_seconds(
            job, source_duration, gpu_core_count=self._gpu_core_count()
        )
        self._raise_if_cancelled()
        with self._stereo_input_path(input_path, progress, channels=source_format.channels) as separator_input_path:
            self._raise_if_cancelled()
            output_files = self._with_heartbeat(
                start=0.35,
                end=0.97,
                stage="separating",
                message="Running MLX separation",
                progress=progress,
                work=lambda: separator.separate(str(separator_input_path)),
                expected_seconds=expected_separate,
            )
        self._raise_if_cancelled()
        progress("postprocessing", "Conforming stems to source audio format", 0.94, self.runtime_stats())
        output_files = self._conform_outputs_to_source_format(output_files, source_format)
        output_files = self._finalize_output_files(job, output_files, input_path)
        if not output_files:
            raise RuntimeError(
                "No output stems were created. Check the backend log for the underlying separator error."
            )

        elapsed = time.perf_counter() - started
        completed_at = time.time()
        self._record_render_benchmark(job, input_path, elapsed)
        files = [self._file_result(path) for path in output_files]
        missing_files = [file["path"] for file in files if file["sizeBytes"] <= 0]
        if missing_files:
            raise RuntimeError(
                "Separator returned output paths, but no audio data was written: "
                + ", ".join(missing_files)
            )

        progress("complete", "Done", 1.0, self.runtime_stats())
        post_run = self._build_post_run_stats(
            job=job,
            model_hot=model_hot,
            resolved_batch_size=resolved_batch_size,
            source_duration_seconds=source_duration,
            elapsed_seconds=elapsed,
        )
        # Attach the same run stats to each stem for the Results Info UI,
        # and refresh sidecars so Info still works after app restart.
        for file in files:
            file["runInfo"] = dict(post_run)
            file["runInfo"]["stem"] = file.get("stem")
            file["runInfo"]["path"] = file.get("path")
            self._write_run_sidecar(Path(file["path"]), job, post_run=post_run)
        return {
            "model": job.model_filename,
            "preset": job.preset,
            "processPresetID": job.process_preset_id,
            "processPresetTitle": job.process_preset_title,
            "startedAt": started_at,
            "completedAt": completed_at,
            "elapsedSeconds": round(elapsed, 2),
            "files": files,
            "metrics": getattr(separator, "last_perf_metrics", None),
            "modelHot": model_hot,
            "modelCache": self.model_cache(),
            "postRunStats": post_run,
            "settings": {
                "chunkDuration": job.chunk_duration,
                "mdxcSegmentSize": job.mdxc_segment_size,
                "mdxcOverlap": job.mdxc_overlap,
                "mdxcBatchSize": resolved_batch_size,
                "mdxcOverrideModelSegmentSize": job.mdxc_override_model_segment_size,
                "speedMode": job.speed_mode,
                "processPresetTitle": job.process_preset_title,
            },
        }

    def _raise_if_cancelled(self):
        if self._cancel_event.is_set():
            raise BackendOperationCancelled(self._cancel_reason)

    def _build_post_run_stats(
        self,
        job: SeparationJob,
        model_hot: bool,
        resolved_batch_size: int,
        source_duration_seconds: float | None,
        elapsed_seconds: float,
    ) -> dict:
        """Compact stats for the Last Run / Post Run Stats UI panel."""
        duration = float(source_duration_seconds or 0)
        chunk = job.chunk_duration
        if chunk and float(chunk) > 0 and duration > 0:
            estimated_chunks = int(math.ceil(duration / float(chunk)))
            chunk_label = f"{int(float(chunk))}s"
        else:
            estimated_chunks = 1 if duration > 0 else 0
            chunk_label = "off"

        enabled_flags = sorted(
            key for key, value in (job.performance_flags or {}).items() if value
        )
        realtime = (duration / elapsed_seconds) if elapsed_seconds > 0 and duration > 0 else None

        return {
            "modelHot": bool(model_hot),
            "processPresetID": job.process_preset_id,
            "processPresetTitle": job.process_preset_title or job.process_preset_id,
            "modelFilename": job.model_filename,
            "modelPreset": job.preset,
            "sourceDurationSeconds": round(duration, 2) if duration > 0 else None,
            "elapsedSeconds": round(float(elapsed_seconds), 2),
            "realtimeFactor": round(realtime, 3) if realtime is not None else None,
            "chunkDurationSeconds": float(chunk) if chunk not in (None, 0, "0", "") else None,
            "chunkLabel": chunk_label,
            "estimatedChunks": estimated_chunks,
            "segmentSize": job.mdxc_segment_size,
            "overlap": job.mdxc_overlap,
            "batchSize": int(resolved_batch_size),
            "batchExplicit": bool(job.mdxc_batch_size_explicit),
            "overrideModelSegment": bool(job.mdxc_override_model_segment_size),
            "speedMode": job.speed_mode,
            "outputFormat": job.output_format,
            "experimentalFlagsEnabled": len(enabled_flags),
            "experimentalFlags": enabled_flags,
        }

    def _build_performance_params(self, job: SeparationJob) -> dict:
        # Defaults reproduce the previous hard-coded behavior. Any experimental
        # flag supplied via job.performance_flags overrides the default.
        # auto_tune_batch stays OFF unless a caller explicitly opts in —
        # never on the hot Separate path.
        base = {
            "experimental_roformer_fast_norm": False,
            "experimental_roformer_grouped_band_split": False,
            "experimental_roformer_grouped_mask_estimator": False,
            "experimental_roformer_fused_overlap_add": False,
            "experimental_roformer_compile_fullgraph": False,
            "experimental_flac_fast_write": job.output_format == "FLAC",
            "auto_tune_batch": False,
        }
        base.update(dict(job.performance_flags or {}))
        return {
            "speed_mode": job.speed_mode,
            "cache_clear_policy": job.cache_clear_policy,
            "write_workers": job.write_workers,
            **base,
        }

    def _separator_fingerprint(self, job: SeparationJob, batch_size: int | None = None) -> str:
        perf = job.performance_flags or {}
        perf_key = "|".join(f"{key}={perf.get(key)}" for key in sorted(perf.keys()))
        resolved_batch = job.mdxc_batch_size if batch_size is None else batch_size
        return "|".join(
            [
                job.model_filename or "",
                str(job.mdxc_segment_size),
                str(job.mdxc_override_model_segment_size),
                str(resolved_batch),
                str(job.mdxc_overlap),
                str(job.speed_mode or ""),
                str(job.cache_clear_policy or ""),
                str(job.output_format or ""),
                str(job.chunk_duration),
                str(job.save_converted_safetensors),
                perf_key,
            ]
        )

    def _total_ram_bytes(self) -> int:
        from . import runtime

        return runtime.total_physical_memory_bytes()

    def _resolve_mdxc_batch_size(self, job: SeparationJob) -> int:
        # K8: static RAM heuristic. Never runs a cold auto_tune probe on the
        # hot Separate path — explicit job intent is always respected.
        from . import runtime

        explicit = job.mdxc_batch_size if job.mdxc_batch_size_explicit else None
        return runtime.resolve_batch_size(self._total_ram_bytes(), explicit=explicit)

    def invalidate_model_cache(self, reason: str = "") -> None:
        if self._cached_separator is not None:
            self.logger.info("Invalidating Separator cache: %s", reason or "requested")
        self._cached_separator = None
        self._cached_model_filename = None
        self._cached_fingerprint = None

    def _get_or_load_separator(
        self, job: SeparationJob, progress: ProgressCallback
    ) -> tuple[object, bool]:
        from mlx_audio_separator import Separator

        fingerprint = self._separator_fingerprint(job, batch_size=self._resolve_mdxc_batch_size(job))
        if (
            self._cached_separator is not None
            and self._cached_model_filename == job.model_filename
            and self._cached_fingerprint == fingerprint
        ):
            self.logger.info("Reusing cached Separator for %s (warm cache hit)", job.model_filename)
            progress("loading", "Reusing loaded model (warm cache)", 0.30, self.runtime_stats())
            return self._cached_separator, True

        if self._cached_separator is not None:
            self.logger.info(
                "Discarding cached Separator: fingerprint changed (cached=%r, requested=%r)",
                self._cached_fingerprint,
                fingerprint,
            )

        performance_params = self._build_performance_params(job)
        resolved_batch_size = self._resolve_mdxc_batch_size(job)
        mdxc_params = {
            "segment_size": job.mdxc_segment_size,
            "override_model_segment_size": job.mdxc_override_model_segment_size,
            "batch_size": resolved_batch_size,
            "overlap": job.mdxc_overlap,
            "pitch_shift": 0,
        }
        # output_dir here is only a bootstrap placeholder; every separate() call
        # rebinds it to the job stems folder via _set_separator_output_dir.
        separator = Separator(
            model_file_dir=self.model_dir,
            output_dir=str(self.model_dir),
            output_format=job.output_format,
            normalization_threshold=job.normalization,
            amplification_threshold=job.amplification,
            chunk_duration=job.chunk_duration,
            mdxc_params=mdxc_params,
            performance_params=performance_params,
            save_converted_safetensors=job.save_converted_safetensors,
        )
        if hasattr(separator, "_set_strict_separation_errors"):
            separator._set_strict_separation_errors(True)

        progress("loading", self._model_load_message(job.model_filename), 0.05, self.runtime_stats())
        self._with_heartbeat(
            start=0.06,
            end=0.28,
            stage="loading",
            message=self._model_load_message(job.model_filename),
            progress=progress,
            work=lambda: self._load_model(separator, job.model_filename),
        )
        self._raise_if_cancelled()
        progress("model_ready", "Model ready", 0.30, self.runtime_stats())

        self._cached_separator = separator
        self._cached_model_filename = job.model_filename
        self._cached_fingerprint = fingerprint
        return separator, False

    def _force_separator_batch_size(self, separator, batch_size: int) -> None:
        """Ensure UI batch survives latency_safe_* overrides inside mlx-audio-separator."""
        batch_size = max(1, int(batch_size))
        try:
            if hasattr(separator, "arch_specific_params"):
                for arch in ("MDXC", "MDX", "VR", "Demucs"):
                    if arch in separator.arch_specific_params:
                        separator.arch_specific_params[arch]["batch_size"] = batch_size
            if hasattr(separator, "_set_model_batch_size"):
                separator._set_model_batch_size(batch_size)
            model = getattr(separator, "model_instance", None)
            if model is not None and hasattr(model, "batch_size"):
                model.batch_size = batch_size
            self.logger.info("Forced separator batch_size=%s after speed-mode init", batch_size)
        except Exception as exc:
            self.logger.warning("Could not force batch_size=%s: %s", batch_size, exc)

    def _set_separator_output_dir(self, separator, output_dir: Path | str) -> None:
        """Point both Separator and its loaded model at the job stems folder."""
        out_path = Path(output_dir).expanduser()
        out_path.mkdir(parents=True, exist_ok=True)
        # Prefer Path so Path / "file.wav" works; os.path.join also accepts PathLike.
        out: Path | str = out_path
        try:
            separator.output_dir = out
            model = getattr(separator, "model_instance", None)
            if model is not None:
                if hasattr(model, "output_dir"):
                    model.output_dir = out
                # Some arch wrappers keep a nested separator with its own path.
                nested = getattr(model, "_demucs_separator", None)
                if nested is not None and hasattr(nested, "output_dir"):
                    nested.output_dir = out
            self.logger.info("Separator output_dir bound to %s", out_path)
        except Exception as exc:
            self.logger.warning("Could not bind separator output_dir to %s: %s", out_path, exc)

    def _expected_separation_seconds(
        self,
        job: SeparationJob,
        source_duration: float | None,
        gpu_core_count: int | None = None,
    ) -> float:
        if not source_duration or source_duration <= 0:
            return float(HEARTBEAT_EXPECTED_STAGE_SECONDS)
        try:
            estimate = estimate_render_time(
                self.model_dir,
                model_filename=job.model_filename,
                process_preset_id=job.process_preset_id or "builtin.default",
                audio_duration_seconds=float(source_duration),
                gpu_core_count=gpu_core_count,
            )
            seconds = estimate.get("estimatedSeconds")
            if seconds and float(seconds) > 0:
                return max(60.0, float(seconds))
        except Exception:
            pass
        # Fallback: ~0.5× realtime for heavy RoFormer on Apple Silicon (rough).
        return max(60.0, float(source_duration) * 0.55)

    def _with_heartbeat(
        self,
        start: float,
        end: float,
        stage: str,
        message: str,
        progress: ProgressCallback,
        work,
        expected_seconds: float | None = None,
    ):
        stop = threading.Event()
        result = {}
        error = {}
        stage_started = time.perf_counter()
        expected = float(expected_seconds or HEARTBEAT_EXPECTED_STAGE_SECONDS)

        def heartbeat():
            while not stop.wait(2.0):
                elapsed = time.perf_counter() - stage_started
                value = _heartbeat_progress_value(start, end, elapsed, expected_seconds=expected)
                if self._cancel_event.is_set():
                    progress(stage, f"Cancelling - {_format_elapsed_duration(elapsed)} elapsed", value, self.runtime_stats())
                    return
                progress(stage, _progress_message(message, elapsed), value, self.runtime_stats())

        thread = threading.Thread(target=heartbeat, daemon=True)
        thread.start()
        try:
            self._raise_if_cancelled()
            result["value"] = work()
        except Exception as exc:
            error["error"] = exc
        finally:
            stop.set()
            thread.join(timeout=0.2)

        if "error" in error:
            raise error["error"]
        self._raise_if_cancelled()
        elapsed = time.perf_counter() - stage_started
        progress(stage, _progress_message(message, elapsed), end, self.runtime_stats())
        return result.get("value")

    @contextmanager
    def _stereo_input_path(self, input_path: Path, progress: ProgressCallback, channels: int | None = None):
        if channels is None:
            channels = self._audio_channel_count(input_path)
        if channels == 2 or channels is None:
            yield input_path
            return

        with tempfile.TemporaryDirectory(prefix="kirtan-splitter-stereo-") as temp_dir:
            prepared_path = Path(temp_dir) / f"{input_path.stem}.stereo.wav"
            self.logger.info(
                "Preparing %s-channel input as stereo for MLX model compatibility: %s",
                channels,
                prepared_path,
            )
            progress(
                "preparing",
                f"Preparing {channels}-channel audio for stereo model input",
                0.32,
                self.runtime_stats(),
            )
            self._convert_to_stereo(input_path, prepared_path)
            self._raise_if_cancelled()
            yield prepared_path

    def _source_audio_format(self, input_path: Path) -> AudioFormatSpec:
        # One ffprobe JSON call for all fields (channels / sample_rate /
        # bit_depth / codec_name) — not four separate probes.
        try:
            output = subprocess.check_output(
                [
                    ffprobe_bin(),
                    "-v",
                    "error",
                    "-select_streams",
                    "a:0",
                    "-show_entries",
                    "stream=channels,sample_rate,bits_per_raw_sample,bits_per_sample,sample_fmt,codec_name",
                    "-of",
                    "json",
                    str(input_path),
                ],
                text=True,
                timeout=20,
            )
            payload = json.loads(output)
            stream = (payload.get("streams") or [{}])[0]
        except Exception as exc:
            self.logger.warning("Could not inspect source audio format for %s: %s", input_path, exc)
            return AudioFormatSpec(
                channels=None,
                sample_rate=None,
                bit_depth=None,
                codec_name=None,
            )

        channels = int(stream.get("channels") or 0) or None
        sample_rate = int(stream.get("sample_rate") or 0) or None
        bit_depth = _bit_depth_from_stream(stream)
        codec_name = stream.get("codec_name") or None
        return AudioFormatSpec(
            channels=channels,
            sample_rate=sample_rate,
            bit_depth=bit_depth,
            codec_name=codec_name,
        )

    def _conform_outputs_to_source_format(
        self,
        output_files,
        source_format: AudioFormatSpec,
    ) -> list[str]:
        restored = []
        for output_file in output_files or []:
            path = Path(output_file)
            current_channels = self._audio_channel_count(path)
            current_sample_rate = self._audio_sample_rate(path)
            current_bit_depth = self._audio_bit_depth(path)
            current_codec = self._audio_codec_name(path)
            target_codec = self._codec_for_source_format(path, source_format)
            needs_channels = source_format.channels is not None and current_channels != source_format.channels
            needs_sample_rate = source_format.sample_rate is not None and current_sample_rate != source_format.sample_rate
            needs_bit_depth = source_format.bit_depth is not None and current_bit_depth != source_format.bit_depth
            needs_codec = target_codec is not None and current_codec != target_codec
            if needs_channels or needs_sample_rate or needs_bit_depth or needs_codec:
                self.logger.info(
                    "Conforming output to source format output=%s channels=%s->%s "
                    "sample_rate=%s->%s bit_depth=%s->%s codec=%s->%s",
                    path,
                    current_channels,
                    source_format.channels,
                    current_sample_rate,
                    source_format.sample_rate,
                    current_bit_depth,
                    source_format.bit_depth,
                    current_codec,
                    target_codec,
                )
                self._convert_output_audio_format(
                    path,
                    channels=source_format.channels,
                    sample_rate=source_format.sample_rate,
                    codec=target_codec,
                )
            restored.append(str(path))
        return restored

    def _finalize_output_files(self, job: SeparationJob, output_files, source_path: Path) -> list[str]:
        target_dir = Path(job.output_dir).expanduser()
        target_dir.mkdir(parents=True, exist_ok=True)
        finalized = []
        for output_file in output_files or []:
            path = self._rename_temporary_stereo_output(Path(output_file), source_path)

            # Always land stems in job.output_dir (…/Song_stems), never model cache.
            if path.parent.resolve() != target_dir.resolve():
                relocated = target_dir / path.name
                try:
                    if path.exists():
                        if relocated.exists():
                            relocated = self._allocate_versioned_stem_path(
                                relocated, source_path, ignore_paths={path.resolve()}
                            )
                        path.replace(relocated)
                        path = relocated
                        self.logger.info("Moved stem out of model dir into %s", path)
                except Exception as exc:
                    self.logger.warning("Failed to relocate %s -> %s: %s", path, relocated, exc)

            model_display = display_name_for_model(job.model_filename)
            if not model_display:
                model_display = Path(job.model_filename).stem
            suffix = model_display

            safe_suffix = re.sub(r'[\\/*?:"<>|]', "", suffix).strip()
            safe_suffix = re.sub(r'\s+', ' ', safe_suffix).strip()

            # Canonical role for filename _(role)_ — remap known mislabeled checkpoints.
            raw_role = None
            match = re.search(r"\(([^)]+)\)", path.name)
            if match:
                raw_role = match.group(1)
            else:
                raw_role = self._stem_name(path)
            role = self._canonical_stem_role(job.model_filename, raw_role)
            # Title-case for display token: Lead / Back / Vocals…
            role_label = role.replace("_", " ").strip().title() if role else "Stem"
            prefix = f"{source_path.stem}_({role_label})"

            desired = path.with_name(f"{prefix}_{safe_suffix}{path.suffix}")

            # Experiment-friendly naming: vocals, vocals 2, vocals 3… never overwrite.
            target = self._allocate_versioned_stem_path(
                desired,
                source_path,
                ignore_paths={path.resolve(), Path(output_file).resolve()},
            )
            if path.resolve() != target.resolve():
                try:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    if path.exists():
                        path.replace(target)
                    path = target
                except Exception as exc:
                    self.logger.warning("Failed to move output %s -> %s: %s", path, target, exc)

            self._write_output_metadata(path, job)
            # Sidecar written again after post_run stats are known (elapsed, RTF, …).
            self._write_run_sidecar(path, job)
            finalized.append(str(path))
        return finalized

    def _allocate_versioned_stem_path(
        self,
        desired: Path,
        source_path: Path,
        ignore_paths: set[Path] | None = None,
    ) -> Path:
        """Pick vocals / vocals 2 / … so re-runs keep previous experiment files.

        Uses the ``_(role)`` token in the filename. Existing files with the same
        role version in the output folder block that version (up to 99).
        Paths in ``ignore_paths`` (the file being renamed) are not treated as
        collisions.
        """
        parent = desired.parent
        parent.mkdir(parents=True, exist_ok=True)
        ignore = {p.resolve() for p in (ignore_paths or set()) if p}
        match = re.search(r"^(?P<prefix>.+)_\((?P<role>[^)]+)\)(?P<rest>.*)$", desired.stem)
        if match:
            prefix = match.group("prefix")
            raw_role = match.group("role").strip()
            rest = match.group("rest")
        else:
            prefix = source_path.stem
            raw_role = self._stem_name(desired).replace("_", " ") or "stem"
            rest = ""

        base_role = re.sub(r"\s+\d+$", "", raw_role).strip() or raw_role
        ext = desired.suffix

        for version in range(1, 100):
            role_label = base_role if version == 1 else f"{base_role} {version}"
            candidate = parent / f"{prefix}_({role_label}){rest}{ext}"
            try:
                if candidate.resolve() in ignore:
                    return candidate
            except OSError:
                pass
            if candidate.exists() and candidate.resolve() not in ignore:
                continue
            claimed = False
            for existing in parent.iterdir():
                if not existing.is_file():
                    continue
                try:
                    if existing.resolve() in ignore:
                        continue
                except OSError:
                    continue
                existing_match = re.search(r"_\(([^)]+)\)", existing.stem)
                if not existing_match:
                    continue
                if existing_match.group(1).strip().lower() == role_label.lower():
                    claimed = True
                    break
            if not claimed:
                return candidate
        return desired

    def _rename_temporary_stereo_output(self, output_path: Path, source_path: Path) -> Path:
        temporary_prefix = f"{source_path.stem}.stereo"
        if not output_path.stem.startswith(temporary_prefix):
            return output_path

        suffix_part = output_path.stem[len(temporary_prefix):]
        target = output_path.with_name(f"{source_path.stem}{suffix_part}{output_path.suffix}")
        if target == output_path:
            return output_path
        # Do not delete existing targets here — versioning happens in finalize.
        if target.exists():
            return output_path
        output_path.replace(target)
        return target

    def _audio_channel_count(self, input_path: Path) -> int | None:
        try:
            output = subprocess.check_output(
                [
                    ffprobe_bin(),
                    "-v",
                    "error",
                    "-select_streams",
                    "a:0",
                    "-show_entries",
                    "stream=channels",
                    "-of",
                    "default=noprint_wrappers=1:nokey=1",
                    str(input_path),
                ],
                text=True,
                timeout=10,
            )
            return int(output.strip())
        except Exception as exc:
            self.logger.warning("Could not inspect audio channel count for %s: %s", input_path, exc)
            return None

    def _audio_sample_rate(self, input_path: Path) -> int | None:
        try:
            output = subprocess.check_output(
                [
                    ffprobe_bin(),
                    "-v",
                    "error",
                    "-select_streams",
                    "a:0",
                    "-show_entries",
                    "stream=sample_rate",
                    "-of",
                    "default=noprint_wrappers=1:nokey=1",
                    str(input_path),
                ],
                text=True,
                timeout=10,
            )
            value = int(output.strip())
            return value if value > 0 else None
        except Exception as exc:
            self.logger.warning("Could not inspect audio sample rate for %s: %s", input_path, exc)
            return None

    def _audio_bit_depth(self, input_path: Path) -> int | None:
        try:
            output = subprocess.check_output(
                [
                    ffprobe_bin(),
                    "-v",
                    "error",
                    "-select_streams",
                    "a:0",
                    "-show_entries",
                    "stream=bits_per_raw_sample,bits_per_sample,sample_fmt",
                    "-of",
                    "json",
                    str(input_path),
                ],
                text=True,
                timeout=10,
            )
            stream = (json.loads(output).get("streams") or [{}])[0]
            value = stream.get("bits_per_raw_sample") or stream.get("bits_per_sample")
            if value and str(value).isdigit():
                depth = int(value)
                return depth if depth > 0 else None
            return _bit_depth_from_sample_format(str(stream.get("sample_fmt") or ""))
        except Exception as exc:
            self.logger.warning("Could not inspect audio bit depth for %s: %s", input_path, exc)
            return None

    def _audio_codec_name(self, input_path: Path) -> str | None:
        try:
            output = subprocess.check_output(
                [
                    ffprobe_bin(),
                    "-v",
                    "error",
                    "-select_streams",
                    "a:0",
                    "-show_entries",
                    "stream=codec_name",
                    "-of",
                    "default=noprint_wrappers=1:nokey=1",
                    str(input_path),
                ],
                text=True,
                timeout=10,
            )
            value = output.strip()
            return value or None
        except Exception as exc:
            self.logger.warning("Could not inspect audio codec for %s: %s", input_path, exc)
            return None

    def _convert_to_stereo(self, input_path: Path, output_path: Path):
        command = [
            ffmpeg_bin(),
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-i",
            str(input_path),
            "-map",
            "0:a:0",
            "-vn",
            "-ac",
            "2",
            "-c:a",
            "pcm_f32le",
            str(output_path),
        ]
        try:
            subprocess.run(command, check=True, capture_output=True, text=True, timeout=None)
        except subprocess.CalledProcessError as exc:
            message = (exc.stderr or exc.stdout or str(exc)).strip()
            raise RuntimeError(f"Failed to prepare stereo input with ffmpeg: {message}") from exc

    def _convert_output_audio_format(
        self,
        output_path: Path,
        channels: int | None,
        sample_rate: int | None,
        codec: str | None = None,
    ):
        temp_path = output_path.with_name(f"{output_path.stem}.format.tmp{output_path.suffix}")
        codec = codec or self._audio_codec_name(output_path) or ("flac" if output_path.suffix.lower() == ".flac" else "pcm_f32le")
        command = [
            ffmpeg_bin(),
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-i",
            str(output_path),
            "-map",
            "0:a:0",
            "-vn",
            "-c:a",
            codec,
        ]
        if channels is not None:
            command.extend(["-ac", str(channels)])
        if sample_rate is not None:
            command.extend(["-ar", str(sample_rate)])
        command.append(str(temp_path))
        try:
            subprocess.run(command, check=True, capture_output=True, text=True, timeout=None)
            temp_path.replace(output_path)
        except subprocess.CalledProcessError as exc:
            temp_path.unlink(missing_ok=True)
            message = (exc.stderr or exc.stdout or str(exc)).strip()
            raise RuntimeError(f"Failed to restore output audio format with ffmpeg: {message}") from exc

    def _codec_for_source_format(
        self,
        output_path: Path,
        source_format: AudioFormatSpec,
    ) -> str | None:
        if output_path.suffix.lower() == ".flac":
            return "flac"
        if output_path.suffix.lower() != ".wav":
            return None
        if source_format.codec_name in {"pcm_f32le", "pcm_f32be"}:
            return "pcm_f32le"
        if source_format.codec_name in {"pcm_s16le", "pcm_s16be"}:
            return "pcm_s16le"
        if source_format.codec_name in {"pcm_s24le", "pcm_s24be"}:
            return "pcm_s24le"
        if source_format.codec_name in {"pcm_s32le", "pcm_s32be"}:
            return "pcm_s32le"
        if source_format.bit_depth == 16:
            return "pcm_s16le"
        if source_format.bit_depth == 24:
            return "pcm_s24le"
        if source_format.bit_depth == 32:
            return "pcm_s32le"
        return None

    def _write_output_metadata(self, output_path: Path, job: SeparationJob):
        if not output_path.exists():
            return
        temp_path = output_path.with_name(f"{output_path.stem}.metadata.tmp{output_path.suffix}")
        command = [
            ffmpeg_bin(),
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-i",
            str(output_path),
            "-map",
            "0:a:0",
            "-vn",
            "-c:a",
            "copy",
            "-metadata",
            "encoded_by=AuraSplitter",
            "-metadata",
            f"comment={self._output_metadata_comment(job)}",
            str(temp_path),
        ]
        try:
            subprocess.run(command, check=True, capture_output=True, text=True, timeout=None)
            temp_path.replace(output_path)
        except subprocess.CalledProcessError as exc:
            temp_path.unlink(missing_ok=True)
            message = (exc.stderr or exc.stdout or str(exc)).strip()
            self.logger.warning("Failed to write output metadata for %s: %s", output_path, message)

    def _write_run_sidecar(
        self,
        output_path: Path,
        job: SeparationJob,
        post_run: dict | None = None,
    ) -> None:
        """JSON next to each stem so Results → Info can show full process settings later."""
        if not output_path.exists():
            return
        sidecar = output_path.with_name(f"{output_path.stem}.aura-run.json")
        payload = {
            "formatVersion": 1,
            "writtenAt": time.time(),
            "stem": self._stem_name(output_path),
            "path": str(output_path),
            "modelFilename": job.model_filename,
            "modelDisplayName": self._display_model_name(job.model_filename, Path(job.model_filename).stem),
            "modelPreset": job.preset,
            "processPresetID": job.process_preset_id,
            "processPresetTitle": job.process_preset_title or job.process_preset_id,
            "outputFormat": job.output_format,
            "chunkDuration": job.chunk_duration,
            "chunkLabel": (
                "off"
                if job.chunk_duration in (None, 0, "0", "")
                else f"{int(float(job.chunk_duration))}s"
            ),
            "segmentSize": job.mdxc_segment_size,
            "overlap": job.mdxc_overlap,
            "batchSize": job.mdxc_batch_size,
            "overrideModelSegment": job.mdxc_override_model_segment_size,
            "speedMode": job.speed_mode,
            "performanceFlags": dict(job.performance_flags or {}),
        }
        if post_run:
            payload.update(
                {
                    "modelHot": post_run.get("modelHot"),
                    "sourceDurationSeconds": post_run.get("sourceDurationSeconds"),
                    "elapsedSeconds": post_run.get("elapsedSeconds"),
                    "realtimeFactor": post_run.get("realtimeFactor"),
                    "estimatedChunks": post_run.get("estimatedChunks"),
                    "batchSize": post_run.get("batchSize", payload["batchSize"]),
                    "chunkLabel": post_run.get("chunkLabel", payload["chunkLabel"]),
                    "experimentalFlagsEnabled": post_run.get("experimentalFlagsEnabled"),
                }
            )
        try:
            sidecar.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        except OSError as exc:
            self.logger.warning("Failed to write run sidecar for %s: %s", output_path, exc)

    def _output_metadata_comment(self, job: SeparationJob) -> str:
        model_name = self._display_model_name(job.model_filename, Path(job.model_filename).stem)
        process_title = job.process_preset_title or job.process_preset_id
        chunk = (
            "off"
            if job.chunk_duration in (None, 0, "0", "")
            else f"{int(float(job.chunk_duration))}s"
        )
        return (
            f"AuraSplitter model={model_name}; "
            f"checkpoint={job.model_filename}; "
            f"preset={job.preset}; "
            f"process={process_title}; "
            f"chunk={chunk}; "
            f"segment={job.mdxc_segment_size}; "
            f"overlap={job.mdxc_overlap}; "
            f"batch={job.mdxc_batch_size}; "
            f"speed={job.speed_mode}"
        )

    def _is_model_downloaded(self, filename: str) -> bool:
        entry = get_model_pack_entry(filename)
        if entry:
            if entry.assets:
                return all((Path(self.model_dir) / asset.filename).is_file() for asset in entry.assets)
            return (Path(self.model_dir) / filename).is_file()
        stem = Path(filename).stem
        model_path = Path(self.model_dir) / filename
        if model_path.exists():
            return True
        return any(Path(self.model_dir).glob(f"{stem}*"))

    def _display_model_name(self, filename: str, fallback: str) -> str:
        catalog_name = display_name_for_model(filename)
        if catalog_name:
            return catalog_name
        if filename in UVR_MODEL_ALIASES:
            return UVR_MODEL_ALIASES[filename]
        metadata = metadata_for_model_stem(Path(filename).stem)
        if metadata and metadata.get("displayName"):
            return str(metadata["displayName"])
        return fallback

    def _model_load_message(self, filename: str) -> str:
        entry = get_model_pack_entry(filename)
        if entry and not self._is_model_downloaded(filename):
            return f"Downloading {entry.title} model pack files"
        stem = Path(filename).stem
        model_path = Path(self.model_dir) / filename
        converted_path = Path(self.model_dir) / f"{stem}.safetensors"
        if converted_path.exists():
            return "Using converted MLX model"
        if model_path.exists():
            return "Converting model for MLX on first run"
        return "Downloading and converting model for MLX on first run"

    def _load_model(self, separator, filename: str):
        attach_model_pack_to_separator(separator)
        ensure_model_pack_assets(filename, self.model_dir, self.logger)
        return separator.load_model(model_filename=filename)

    def _file_result(self, path_value: str) -> dict:
        path = Path(path_value)
        if not path.is_absolute():
            path = Path.cwd() / path
        return {
            "stem": self._stem_name(path),
            "path": str(path),
            "sizeBytes": path.stat().st_size if path.exists() else 0,
        }

    def _stem_name(self, path: Path) -> str:
        match = re.search(r"_\(([^)]+)\)", path.stem)
        if match:
            # "vocals 2" -> "vocals_2" for stable stem IDs in the UI.
            return match.group(1).strip().lower().replace(" ", "_")
        suffix = path.stem.split("_")[-1]
        return suffix.strip().lower().replace(" ", "_")

    def _canonical_stem_role(self, model_filename: str | None, role: str | None) -> str:
        """Normalize stem labels; fix checkpoints whose YAML names are inverted.

        Aura Lead / Back 2 (karaoke_bs_roformer_anvuew) — verified by ear:
          - YAML "Vocals"        → actual **lead** vocal
          - YAML "Instrumental"  → actual **back** / bed
        (Previous mapping had these swapped.)
        """
        if not role:
            return "stem"
        role_n = str(role).strip().lower().replace(" ", "_").replace("-", "_")
        role_n = re.sub(r"_+\d+$", "", role_n)

        name = Path(model_filename or "").name.lower()
        stem = Path(model_filename or "").stem.lower()
        is_anvuew_karaoke = (
            "karaoke_bs_roformer_anvuew" in name
            or "karaoke_bs_roformer_anvuew" in stem
            or name.startswith("karaoke_bs_roformer_anvuew")
        )
        if is_anvuew_karaoke:
            # Raw checkpoint labels → correct role names.
            if role_n in {"vocals", "vocal"}:
                return "lead"
            if role_n in {"instrumental", "instrument", "instruments", "inst", "other", "rest"}:
                return "back"
            # Already renamed on a prior pass — keep.
            if role_n in {"lead", "lead_vocal", "lead_vocals"}:
                return "lead"
            if role_n in {"back", "back_vocal", "back_vocals", "backing", "backing_vocals"}:
                return "back"

        return role_n

    def _record_render_benchmark(self, job: SeparationJob, input_path: Path, elapsed_seconds: float) -> None:
        duration_seconds = self._audio_duration_seconds(input_path)
        if not duration_seconds:
            self.logger.info("Skipping render benchmark because audio duration is unavailable: %s", input_path)
            return
        try:
            record_render_benchmark(
                self.model_dir,
                {
                    "modelFilename": job.model_filename,
                    "modelPresetID": job.preset,
                    "processPresetID": job.process_preset_id,
                    "processPresetTitle": job.process_preset_title,
                    "elapsedSeconds": elapsed_seconds,
                    "audioDurationSeconds": duration_seconds,
                    "gpuCoreCount": self._gpu_core_count(),
                    "settings": {
                        "chunkDuration": job.chunk_duration,
                        "mdxcSegmentSize": job.mdxc_segment_size,
                        "mdxcOverlap": job.mdxc_overlap,
                        "mdxcBatchSize": job.mdxc_batch_size,
                        "mdxcOverrideModelSegmentSize": job.mdxc_override_model_segment_size,
                        "speedMode": job.speed_mode,
                        "outputFormat": job.output_format,
                    },
                },
            )
        except Exception as exc:
            self.logger.warning("Failed to record render benchmark: %s", exc)

    def _audio_duration_seconds(self, input_path: Path) -> float | None:
        try:
            completed = subprocess.run(
                [
                    ffprobe_bin(),
                    "-v",
                    "error",
                    "-show_entries",
                    "format=duration",
                    "-of",
                    "default=noprint_wrappers=1:nokey=1",
                    str(input_path),
                ],
                capture_output=True,
                text=True,
                check=True,
            )
            duration = float(completed.stdout.strip())
        except (subprocess.CalledProcessError, ValueError, OSError):
            return None
        return duration if duration > 0 else None

    def _gpu_core_count(self) -> int | None:
        try:
            value = self.runtime_stats().get("gpu", {}).get("gpuCoreCount")
            core_count = int(value)
        except (TypeError, ValueError):
            return None
        return core_count if core_count > 0 else None
