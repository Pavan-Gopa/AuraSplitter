from __future__ import annotations

import logging
import math
import os
import re
import subprocess
import tempfile
import threading
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Callable

from .audio_analysis import analyze_audio
from .jobs import SeparationJob
from .model_catalog import (
    attach_model_pack_to_separator,
    display_name_for_model,
    ensure_model_pack_assets,
    get_model_pack_entry,
)
from .onnx_backend import DemucsOnnxBackend, onnx_runtime_status
from .render_estimates import estimate_render_time, record_render_benchmark
from .runtime import delete_model_cache_item, delete_model_group_source, model_cache, runtime_stats

ProgressCallback = Callable[[str, str, float, dict | None], None]

HEARTBEAT_EXPECTED_STAGE_SECONDS = 30 * 60
HEARTBEAT_FRACTION_CAP = 0.92
HEARTBEAT_CURVE_SECONDS = 10


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
    if end <= start:
        return end

    elapsed = max(0.0, float(elapsed_seconds))
    expected = max(1.0, float(expected_seconds))
    denominator = math.log1p(expected / HEARTBEAT_CURVE_SECONDS)
    if denominator <= 0:
        fraction = 0.0
    else:
        fraction = math.log1p(elapsed / HEARTBEAT_CURVE_SECONDS) / denominator
    fraction = min(HEARTBEAT_FRACTION_CAP, max(0.0, fraction))
    return start + (end - start) * fraction

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

    def runtime_stats(self) -> dict:
        return runtime_stats(self.model_dir)

    def model_cache(self) -> dict:
        return model_cache(self.model_dir)

    def delete_model_cache_item(self, item_path: str) -> dict:
        return delete_model_cache_item(self.model_dir, item_path)

    def delete_model_group_source(self, group_id: str) -> dict:
        return delete_model_group_source(self.model_dir, group_id)

    def analyze_audio(self, path: str, waveform_points: int = 8192, spectrogram_columns: int = 8192, spectrogram_bins: int = 224) -> dict:
        return analyze_audio(path, waveform_points, spectrogram_columns, spectrogram_bins)

    def render_estimate(self, params: dict, model_filename: str) -> dict:
        duration_seconds = params.get("durationSeconds") or params.get("duration_seconds")
        if duration_seconds in (None, "", 0, "0"):
            input_path = params.get("inputPath") or params.get("path")
            duration_seconds = self._audio_duration_seconds(Path(str(input_path)).expanduser()) if input_path else None
        process_preset_id = str(params.get("processPresetID", params.get("process_preset_id", "builtin.default")))
        gpu_core_count = params.get("gpuCoreCount", params.get("gpu_core_count"))
        if gpu_core_count in (None, "", 0, "0"):
            gpu_core_count = self._gpu_core_count()
        return estimate_render_time(
            self.model_dir,
            model_filename=model_filename,
            process_preset_id=process_preset_id,
            audio_duration_seconds=duration_seconds or 0,
            gpu_core_count=gpu_core_count,
        )

    def cancel_current(self, reason: str = "User cancelled current operation") -> dict:
        self._cancel_reason = reason
        self._cancel_event.set()
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
        source_channels = self._audio_channel_count(input_path)
        catalog_entry = get_model_pack_entry(job.model_filename)
        if catalog_entry and catalog_entry.backend == "demucs_onnx":
            return self._separate_with_demucs_onnx(
                job=job,
                progress=progress,
                input_path=input_path,
                output_dir=output_dir,
                source_channels=source_channels,
                catalog_entry=catalog_entry,
            )

        progress("loading", self._model_load_message(job.model_filename), 0.05, self.runtime_stats())
        started = time.perf_counter()

        performance_params = {
            "speed_mode": job.speed_mode,
            "cache_clear_policy": job.cache_clear_policy,
            "write_workers": job.write_workers,
            "experimental_roformer_fast_norm": False,
            "experimental_roformer_grouped_band_split": False,
            "experimental_roformer_grouped_mask_estimator": False,
            "experimental_roformer_fused_overlap_add": False,
            "experimental_roformer_compile_fullgraph": False,
            "experimental_flac_fast_write": job.output_format == "FLAC",
        }
        mdxc_params = {
            "segment_size": job.mdxc_segment_size,
            "override_model_segment_size": job.mdxc_override_model_segment_size,
            "batch_size": job.mdxc_batch_size,
            "overlap": job.mdxc_overlap,
            "pitch_shift": 0,
        }
        self.logger.info(
            "Starting separation input=%s output_dir=%s model=%s preset=%s "
            "output_format=%s chunk_duration=%s mdxc_segment_size=%s "
            "mdxc_overlap=%s mdxc_batch_size=%s mdxc_override_model_segment_size=%s "
            "speed_mode=%s cache_clear_policy=%s write_workers=%s source_channels=%s",
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
            source_channels,
        )

        self._raise_if_cancelled()
        separator = Separator(
            model_file_dir=self.model_dir,
            output_dir=str(output_dir),
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
        with self._stereo_input_path(input_path, progress, channels=source_channels) as separator_input_path:
            self._raise_if_cancelled()
            output_files = self._with_heartbeat(
                start=0.35,
                end=0.92,
                stage="separating",
                message="Running MLX separation",
                progress=progress,
                work=lambda: separator.separate(str(separator_input_path)),
            )
        self._raise_if_cancelled()
        if source_channels == 1:
            progress("postprocessing", "Restoring mono channel layout", 0.94, self.runtime_stats())
            output_files = self._restore_mono_outputs(output_files)
        if not output_files:
            raise RuntimeError(
                "No output stems were created. Check the backend log for the underlying separator error."
            )

        elapsed = time.perf_counter() - started
        self._record_render_benchmark(job, input_path, elapsed)
        files = [self._file_result(path) for path in output_files]
        missing_files = [file["path"] for file in files if file["sizeBytes"] <= 0]
        if missing_files:
            raise RuntimeError(
                "Separator returned output paths, but no audio data was written: "
                + ", ".join(missing_files)
            )

        progress("complete", "Done", 1.0, self.runtime_stats())
        return {
            "model": job.model_filename,
            "preset": job.preset,
            "elapsedSeconds": round(elapsed, 2),
            "files": files,
            "metrics": getattr(separator, "last_perf_metrics", None),
            "modelCache": self.model_cache(),
            "settings": {
                "chunkDuration": job.chunk_duration,
                "mdxcSegmentSize": job.mdxc_segment_size,
                "mdxcOverlap": job.mdxc_overlap,
                "mdxcBatchSize": job.mdxc_batch_size,
                "mdxcOverrideModelSegmentSize": job.mdxc_override_model_segment_size,
                "speedMode": job.speed_mode,
            },
        }

    def _raise_if_cancelled(self):
        if self._cancel_event.is_set():
            raise BackendOperationCancelled(self._cancel_reason)

    def _with_heartbeat(self, start: float, end: float, stage: str, message: str, progress: ProgressCallback, work):
        stop = threading.Event()
        result = {}
        error = {}
        stage_started = time.perf_counter()

        def heartbeat():
            while not stop.wait(2.0):
                elapsed = time.perf_counter() - stage_started
                value = _heartbeat_progress_value(start, end, elapsed)
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

    def _restore_mono_outputs(self, output_files) -> list[str]:
        restored = []
        for output_file in output_files or []:
            path = Path(output_file)
            if self._audio_channel_count(path) == 1:
                restored.append(str(path))
                continue
            self._convert_output_to_mono(path)
            restored.append(str(path))
        return restored

    def _audio_channel_count(self, input_path: Path) -> int | None:
        try:
            output = subprocess.check_output(
                [
                    "ffprobe",
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

    def _convert_to_stereo(self, input_path: Path, output_path: Path):
        command = [
            "ffmpeg",
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

    def _convert_output_to_mono(self, output_path: Path):
        temp_path = output_path.with_name(f"{output_path.stem}.mono.tmp{output_path.suffix}")
        codec = "flac" if output_path.suffix.lower() == ".flac" else "pcm_f32le"
        command = [
            "ffmpeg",
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-i",
            str(output_path),
            "-map",
            "0:a:0",
            "-vn",
            "-ac",
            "1",
            "-c:a",
            codec,
            str(temp_path),
        ]
        try:
            subprocess.run(command, check=True, capture_output=True, text=True, timeout=None)
            temp_path.replace(output_path)
        except subprocess.CalledProcessError as exc:
            temp_path.unlink(missing_ok=True)
            message = (exc.stderr or exc.stdout or str(exc)).strip()
            raise RuntimeError(f"Failed to restore mono output with ffmpeg: {message}") from exc

    def _is_model_downloaded(self, filename: str) -> bool:
        entry = get_model_pack_entry(filename)
        if entry:
            return all((Path(self.model_dir) / asset.filename).is_file() for asset in entry.assets)
        stem = Path(filename).stem
        model_path = Path(self.model_dir) / filename
        if model_path.exists():
            return True
        return any(Path(self.model_dir).glob(f"{stem}*"))

    def _display_model_name(self, filename: str, fallback: str) -> str:
        catalog_name = display_name_for_model(filename)
        if catalog_name:
            return catalog_name
        return UVR_MODEL_ALIASES.get(filename, fallback)

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

    def _separate_with_demucs_onnx(
        self,
        job: SeparationJob,
        progress: ProgressCallback,
        input_path: Path,
        output_dir: Path,
        source_channels: int | None,
        catalog_entry,
    ) -> dict:
        started = time.perf_counter()
        progress(
            "loading",
            f"Preparing {catalog_entry.title} ONNX/CoreML backend",
            0.05,
            self.runtime_stats(),
        )
        backend = DemucsOnnxBackend(self.model_dir, logger=self.logger)
        self._raise_if_cancelled()
        output_files = self._with_heartbeat(
            start=0.08,
            end=0.92,
            stage="separating",
            message=f"Running {catalog_entry.title} ONNX/CoreML separation",
            progress=progress,
            work=lambda: backend.separate(
                input_path=str(input_path),
                output_dir=str(output_dir),
                output_format=job.output_format,
                model=catalog_entry.runner_model or Path(catalog_entry.filename).stem,
            ),
        )
        self._raise_if_cancelled()
        if source_channels == 1:
            progress("postprocessing", "Restoring mono channel layout", 0.94, self.runtime_stats())
            output_files = self._restore_mono_outputs(output_files)
        if not output_files:
            raise RuntimeError("ONNX/CoreML backend completed but did not create any output stems.")

        elapsed = time.perf_counter() - started
        self._record_render_benchmark(job, input_path, elapsed)
        files = [self._file_result(path) for path in output_files]
        missing_files = [file["path"] for file in files if file["sizeBytes"] <= 0]
        if missing_files:
            raise RuntimeError(
                "ONNX/CoreML backend returned output paths, but no audio data was written: "
                + ", ".join(missing_files)
            )

        progress("complete", "Done", 1.0, self.runtime_stats())
        return {
            "model": job.model_filename,
            "preset": job.preset,
            "elapsedSeconds": round(elapsed, 2),
            "files": files,
            "metrics": {"backend": 1.0},
            "modelCache": self.model_cache(),
            "settings": {
                "chunkDuration": job.chunk_duration,
                "mdxcSegmentSize": job.mdxc_segment_size,
                "mdxcOverlap": job.mdxc_overlap,
                "mdxcBatchSize": job.mdxc_batch_size,
                "mdxcOverrideModelSegmentSize": job.mdxc_override_model_segment_size,
                "speedMode": job.speed_mode,
            },
        }

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
            return match.group(1).strip().lower().replace(" ", "_")
        suffix = path.stem.split("_")[-1]
        return suffix.strip().lower().replace(" ", "_")

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
                    "ffprobe",
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
