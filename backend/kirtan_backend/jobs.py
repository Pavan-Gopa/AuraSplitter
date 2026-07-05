from __future__ import annotations

from dataclasses import dataclass


def _bool_param(value) -> bool:
    if isinstance(value, bool):
        return value
    if value is None:
        return False
    if isinstance(value, str):
        return value.strip().lower() in {"1", "true", "yes", "on"}
    return bool(value)


@dataclass(frozen=True)
class SeparationJob:
    input_path: str
    output_dir: str
    model_filename: str
    preset: str
    output_format: str = "FLAC"
    chunk_duration: float | None = None
    mdxc_segment_size: int = 256
    mdxc_overlap: int = 8
    mdxc_batch_size: int = 1
    mdxc_override_model_segment_size: bool = False
    speed_mode: str = "latency_safe_v3"
    cache_clear_policy: str = "deferred"
    write_workers: int = 2
    normalization: float = 0.9
    amplification: float = 0.0
    save_converted_safetensors: bool = True

    @classmethod
    def from_params(cls, params: dict, model_filename: str) -> "SeparationJob":
        input_path = params.get("inputPath") or params.get("input_path")
        output_dir = params.get("outputDir") or params.get("output_dir")
        if not input_path:
            raise ValueError("Missing required parameter: inputPath")
        if not output_dir:
            raise ValueError("Missing required parameter: outputDir")

        chunk_duration = params.get("chunkDuration", params.get("chunk_seconds"))
        if chunk_duration in ("", 0, "0"):
            chunk_duration = None
        elif chunk_duration is not None:
            chunk_duration = float(chunk_duration)

        mdxc_segment_size = int(params.get("mdxcSegmentSize", params.get("mdxc_segment_size", 256)))
        mdxc_overlap = int(params.get("mdxcOverlap", params.get("mdxc_overlap", 8)))
        mdxc_batch_size = int(params.get("mdxcBatchSize", params.get("mdxc_batch_size", 1)))
        mdxc_override = _bool_param(
            params.get(
                "mdxcOverrideModelSegmentSize",
                params.get("mdxc_override_model_segment_size", False),
            )
        )

        return cls(
            input_path=str(input_path),
            output_dir=str(output_dir),
            model_filename=model_filename,
            preset=str(params.get("preset", "kirtan_pro")),
            output_format=str(params.get("outputFormat", "FLAC")).upper(),
            chunk_duration=chunk_duration,
            mdxc_segment_size=mdxc_segment_size,
            mdxc_overlap=mdxc_overlap,
            mdxc_batch_size=mdxc_batch_size,
            mdxc_override_model_segment_size=mdxc_override,
            speed_mode=str(params.get("speedMode", "latency_safe_v3")),
            cache_clear_policy=str(params.get("cacheClearPolicy", "deferred")),
            write_workers=int(params.get("writeWorkers", 2)),
            normalization=float(params.get("normalization", 0.9)),
            amplification=float(params.get("amplification", 0.0)),
            save_converted_safetensors=bool(params.get("saveConvertedSafetensors", True)),
        )
