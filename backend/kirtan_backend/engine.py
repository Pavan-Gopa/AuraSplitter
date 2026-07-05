from __future__ import annotations

import logging
import os
import re
import time
from pathlib import Path
from typing import Callable

from .jobs import SeparationJob

ProgressCallback = Callable[[str, str, float], None]


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

    def list_models(self, limit: int = 80) -> list[dict]:
        from mlx_audio_separator import Separator

        separator = Separator(info_only=True, model_file_dir=self.model_dir)
        simplified = separator.get_simplified_model_list(filter_sort_by="filename")
        models: list[dict] = []
        for filename, info in simplified.items():
            models.append(
                {
                    "filename": filename,
                    "name": info.get("Name", filename),
                    "type": info.get("Type", "Unknown"),
                    "stems": info.get("Stems", []),
                    "sdr": info.get("SDR", {}),
                    "isDownloaded": self._is_model_downloaded(filename),
                }
            )
            if len(models) >= limit:
                break
        return models

    def separate(self, job: SeparationJob, progress: ProgressCallback) -> dict:
        from mlx_audio_separator import Separator

        input_path = Path(job.input_path).expanduser()
        output_dir = Path(job.output_dir).expanduser()
        if not input_path.exists():
            raise FileNotFoundError(f"Input audio file does not exist: {input_path}")
        output_dir.mkdir(parents=True, exist_ok=True)

        progress("loading", f"Loading {job.model_filename}", 0.05)
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

        separator = Separator(
            model_file_dir=self.model_dir,
            output_dir=str(output_dir),
            output_format=job.output_format,
            normalization_threshold=job.normalization,
            amplification_threshold=job.amplification,
            chunk_duration=job.chunk_duration,
            performance_params=performance_params,
            save_converted_safetensors=job.save_converted_safetensors,
        )
        separator.load_model(model_filename=job.model_filename)

        progress("separating", "Running MLX separation", 0.35)
        output_files = separator.separate(str(input_path))
        elapsed = time.perf_counter() - started
        files = [self._file_result(path) for path in output_files]

        progress("complete", "Done", 1.0)
        return {
            "model": job.model_filename,
            "preset": job.preset,
            "elapsedSeconds": round(elapsed, 2),
            "files": files,
            "metrics": getattr(separator, "last_perf_metrics", None),
        }

    def _is_model_downloaded(self, filename: str) -> bool:
        stem = Path(filename).stem
        model_path = Path(self.model_dir) / filename
        if model_path.exists():
            return True
        return any(Path(self.model_dir).glob(f"{stem}*"))

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
