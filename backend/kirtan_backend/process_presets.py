from __future__ import annotations

PROCESS_PRESETS: dict[str, dict] = {
    "builtin.fast": {
        "id": "builtin.fast",
        "title": "Fast 512",
        "settings": {
            "mdxcSegmentSize": 512,
            "mdxcOverlap": 8,
            "mdxcBatchSize": 1,
            "mdxcOverrideModelSegmentSize": True,
            "speedMode": "latency_safe_v3",
            "chunkDuration": 30,
            "outputFormat": "WAV",
        },
    },
    "builtin.heavy": {
        "id": "builtin.heavy",
        "title": "Heavy 1024",
        "settings": {
            "mdxcSegmentSize": 1024,
            "mdxcOverlap": 10,
            "mdxcBatchSize": 2,
            "mdxcOverrideModelSegmentSize": True,
            "speedMode": "latency_safe_v3",
            "chunkDuration": 30,
            "outputFormat": "WAV",
        },
    },
    "builtin.extreme": {
        "id": "builtin.extreme",
        "title": "Extreme 4096",
        "settings": {
            "mdxcSegmentSize": 4096,
            "mdxcOverlap": 12,
            "mdxcBatchSize": 1,
            "mdxcOverrideModelSegmentSize": True,
            "speedMode": "latency_safe_v3",
            "chunkDuration": 30,
            "outputFormat": "WAV",
        },
    },
    "metal.fast": {
        "id": "metal.fast",
        "title": "Metal Fast",
        "summary": "Safe experimental RoFormer kernels; no graph compile. auto_tune_batch stays OFF.",
        "settings": {
            "mdxcSegmentSize": 512,
            "mdxcOverlap": 8,
            "mdxcBatchSize": 1,
            "mdxcOverrideModelSegmentSize": True,
            "speedMode": "latency_safe_v3",
            "chunkDuration": 30,
            "outputFormat": "WAV",
            "performanceFlags": {
                "experimental_roformer_fast_norm": True,
                "experimental_roformer_grouped_band_split": True,
                "experimental_roformer_grouped_mask_estimator": True,
                "experimental_roformer_fused_overlap_add": True,
                "experimental_flac_fast_write": True,
            },
        },
    },
    "metal.max": {
        "id": "metal.max",
        "title": "Metal Max",
        "summary": (
            "Aggressive experimental kernels plus graph compile for maximum "
            "throughput. auto_tune_batch stays OFF (no cold 8s probe on Separate)."
        ),
        "settings": {
            "mdxcSegmentSize": 1024,
            "mdxcOverlap": 10,
            "mdxcBatchSize": 2,
            "mdxcOverrideModelSegmentSize": True,
            "speedMode": "latency_safe_v3",
            "chunkDuration": 30,
            "outputFormat": "WAV",
            "performanceFlags": {
                "experimental_roformer_fast_norm": True,
                "experimental_roformer_grouped_band_split": True,
                "experimental_roformer_grouped_mask_estimator": True,
                "experimental_roformer_fused_overlap_add": True,
                "experimental_roformer_compile_fullgraph": True,
                "experimental_compile_model_forward": True,
                "experimental_compile_shapeless": True,
                "experimental_roformer_static_compiled_demix": True,
                "experimental_mlx_stream_pipeline": True,
                "experimental_roformer_grouped_weight_cache": True,
                "experimental_roformer_chunk_gather_batching": True,
                "experimental_roformer_ola_simd_tuning": True,
                "experimental_mdxc_defer_batch_eval": True,
                "experimental_mdxc_precompute_gather_idx": True,
                "experimental_vectorized_chunking": True,
                "experimental_flac_fast_write": True,
            },
        },
    },
}


def process_preset_list() -> list[dict]:
    return list(PROCESS_PRESETS.values())


def resolve_process_preset(preset_id: str) -> dict:
    return PROCESS_PRESETS[preset_id]
