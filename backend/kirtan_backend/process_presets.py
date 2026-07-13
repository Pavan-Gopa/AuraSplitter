from __future__ import annotations

# Built-in process presets. Titles are plain names only (no segment numbers).
# Order: Default → Fast → Heavy → Max → Extreme
PROCESS_PRESETS: dict[str, dict] = {
    "builtin.default": {
        "id": "builtin.default",
        "title": "Default",
        "settings": {
            "mdxcSegmentSize": 256,
            "mdxcOverlap": 8,
            "mdxcBatchSize": 1,
            "mdxcOverrideModelSegmentSize": False,
            "speedMode": "latency_safe_v3",
            "chunkDuration": 30,
            "outputFormat": "WAV",
        },
    },
    "builtin.fast": {
        "id": "builtin.fast",
        "title": "Fast",
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
        "title": "Heavy",
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
    "builtin.max": {
        "id": "builtin.max",
        "title": "Max",
        "settings": {
            "mdxcSegmentSize": 2048,
            "mdxcOverlap": 12,
            "mdxcBatchSize": 1,
            "mdxcOverrideModelSegmentSize": True,
            "speedMode": "latency_safe_v3",
            "chunkDuration": 30,
            "outputFormat": "WAV",
        },
    },
    "builtin.extreme": {
        "id": "builtin.extreme",
        "title": "Extreme",
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
