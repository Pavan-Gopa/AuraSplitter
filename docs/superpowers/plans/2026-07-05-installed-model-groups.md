# Installed Model Groups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show cached models as installed model groups, hide YAML files, make first-run conversion status explicit, and allow safe source checkpoint removal after `.safetensors` exists.

**Architecture:** Keep `mlx-audio-separator` as the inference engine. Add a KirtanSplitter backend grouping layer that derives one model group from `.ckpt/.safetensors/.yaml`, treats `.safetensors` as the installed MLX artifact, and replaces removable source checkpoints with a tiny placeholder so the upstream loader skips re-download while loading converted weights. Swift consumes `groups` when available and falls back to legacy `items`.

**Tech Stack:** Python backend, pytest, SwiftPM macOS SwiftUI app, `mlx-audio-separator`.

---

### Task 1: Backend Model Groups

**Files:**
- Modify: `backend/kirtan_backend/runtime.py`
- Test: `tests/test_runtime_gpu.py`

- [ ] Add tests for grouped cache output, hidden YAML files, converted/source byte accounting, and source checkpoint placeholder deletion.
- [ ] Add `model_cache_groups(model_dir)` and include `groups` in `model_cache`.
- [ ] Add `delete_model_group_source(model_dir, group_id)` that requires `.safetensors` and `.yaml`, replaces the checkpoint with a small placeholder, and returns refreshed cache.

### Task 2: Backend Protocol And Progress

**Files:**
- Modify: `backend/kirtan_backend/engine.py`
- Modify: `backend/kirtan_backend/protocol.py`
- Test: `tests/test_backend_protocol.py`

- [ ] Add protocol test for `delete_model_group_source`.
- [ ] Add engine load-status helper: `Using converted MLX model`, `Converting model for MLX on first run`, or `Downloading and converting model for MLX on first run`.
- [ ] Wire `delete_model_group_source` through engine and protocol.

### Task 3: Swift Grouped Models UI

**Files:**
- Modify: `Sources/KirtanSplitterApp/Models/RuntimeModels.swift`
- Modify: `Sources/KirtanSplitterApp/Services/BackendClient.swift`
- Modify: `Sources/KirtanSplitterApp/Views/DiagnosticsInspectorView.swift`
- Modify: `Sources/KirtanSplitterApp/Views/ContentView.swift`

- [ ] Decode `ModelCacheGroup`.
- [ ] Render groups instead of raw files; keep legacy fallback.
- [ ] Add `Delete source` action for converted groups with source present.
- [ ] Show a first-run conversion overlay when backend stage reports downloading/converting model.

### Task 4: Verification

**Files:**
- Modify: `README.md`

- [ ] Update docs for installed converted models and source placeholder behavior.
- [ ] Run `./script/test_backend.sh`.
- [ ] Run `swift build`.
- [ ] Run `./script/build_and_run.sh --verify`.
- [ ] Smoke-check live backend `model_cache` groups.
