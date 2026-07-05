from __future__ import annotations

import logging
import os
import re
import subprocess
import tempfile
import threading
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Callable

from .jobs import SeparationJob
from .runtime import delete_model_cache_item, model_cache, runtime_stats

ProgressCallback = Callable[[str, str, float, dict | None], None]

UVR_MODEL_ALIASES = {
    "model_bs_roformer_ep_317_sdr_12.9755.ckpt": "BS-Roformer-Viperx-1297",
    "model_bs_roformer_ep_368_sdr_12.9628.ckpt": "BS-Roformer-Viperx-1296",
    "mel_band_roformer_karaoke_aufr33_viperx_sdr_10.1956.ckpt": "MB-Ro-Kara-AuFR33-Viperx",
}


class MlxSeparatorEngine:
    def __init__(self, model_dir: str, logger: logging.Logger | None = None):
        self.model_dir = str(Path(model_dir).expanduser())
        self.logger = logger or logging.getLogger("kirtan_backend.engine")
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
        }

    def list_models(self, limit: int = 500) -> list[dict]:
        from mlx_audio_separator import Separator

        separator = Separator(info_only=True, model_file_dir=self.model_dir)
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

    def separate(self, job: SeparationJob, progress: ProgressCallback) -> dict:
        from mlx_audio_separator import Separator

        input_path = Path(job.input_path).expanduser()
        output_dir = Path(job.output_dir).expanduser()
        if not input_path.exists():
            raise FileNotFoundError(f"Input audio file does not exist: {input_path}")
        output_dir.mkdir(parents=True, exist_ok=True)

        progress("loading", f"Loading {job.model_filename}", 0.05, self.runtime_stats())
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
            message="Downloading or converting model",
            progress=progress,
            work=lambda: separator.load_model(model_filename=job.model_filename),
        )

        progress("model_ready", "Model ready", 0.30, self.runtime_stats())
        with self._stereo_input_path(input_path, progress) as separator_input_path:
            output_files = self._with_heartbeat(
                start=0.35,
                end=0.92,
                stage="separating",
                message="Running MLX separation",
                progress=progress,
                work=lambda: separator.separate(str(separator_input_path)),
            )
        if not output_files:
            raise RuntimeError(
                "No output stems were created. Check the backend log for the underlying separator error."
            )

        elapsed = time.perf_counter() - started
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

    def _with_heartbeat(self, start: float, end: float, stage: str, message: str, progress: ProgressCallback, work):
        stop = threading.Event()
        result = {}
        error = {}

        def heartbeat():
            started = time.perf_counter()
            while not stop.wait(2.0):
                elapsed = time.perf_counter() - started
                fraction = min(0.95, elapsed / 120.0)
                value = start + (end - start) * fraction
                progress(stage, message, value, self.runtime_stats())

        thread = threading.Thread(target=heartbeat, daemon=True)
        thread.start()
        try:
            result["value"] = work()
        except Exception as exc:
            error["error"] = exc
        finally:
            stop.set()
            thread.join(timeout=0.2)

        if "error" in error:
            raise error["error"]
        progress(stage, message, end, self.runtime_stats())
        return result.get("value")

    @contextmanager
    def _stereo_input_path(self, input_path: Path, progress: ProgressCallback):
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
            yield prepared_path

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

    def _is_model_downloaded(self, filename: str) -> bool:
        stem = Path(filename).stem
        model_path = Path(self.model_dir) / filename
        if model_path.exists():
            return True
        return any(Path(self.model_dir).glob(f"{stem}*"))

    def _display_model_name(self, filename: str, fallback: str) -> str:
        return UVR_MODEL_ALIASES.get(filename, fallback)

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
