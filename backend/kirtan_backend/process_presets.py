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
}


def process_preset_list() -> list[dict]:
    return list(PROCESS_PRESETS.values())


def resolve_process_preset(preset_id: str) -> dict:
    return PROCESS_PRESETS[preset_id]
