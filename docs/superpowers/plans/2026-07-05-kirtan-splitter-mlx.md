# KirtanSplitter MLX Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a native macOS app that separates kirtan recordings with MLX/Metal-backed UVR models.

**Architecture:** SwiftUI launches a local Python backend over JSON-lines IPC. Python delegates model execution to `mlx-audio-separator`, keeps model files local, and returns generated stem paths.

**Tech Stack:** SwiftPM, SwiftUI, Python 3.11, MLX, `mlx-audio-separator`, pytest, ffmpeg.

---

### Task 1: Backend Protocol

**Files:**
- Create: `backend/kirtan_backend/protocol.py`
- Create: `backend/kirtan_backend/engine.py`
- Test: `tests/test_backend_protocol.py`

- [x] Write failing protocol tests for ping, presets, separation, errors.
- [x] Implement request parsing and response/event generation.
- [x] Add MLX engine wrapper with lazy package imports.
- [x] Run `PYTHONPATH=backend .venv/bin/python -m pytest tests/test_backend_protocol.py -q`.

### Task 2: SwiftPM App

**Files:**
- Create: `Package.swift`
- Create: `Sources/KirtanSplitterApp/**`

- [x] Create executable SwiftPM package.
- [x] Add app entrypoint and foreground activation.
- [x] Add backend client, models, control pane, results pane, settings.
- [x] Run `swift build`.

### Task 3: Run Tooling

**Files:**
- Create: `script/setup_backend.sh`
- Create: `script/test_backend.sh`
- Create: `script/build_and_run.sh`
- Create: `.codex/environments/environment.toml`
- Create: `Launch KirtanSplitter.command`

- [x] Add backend setup through `uv`.
- [x] Add fresh build and app-bundle launch script.
- [x] Add Codex Run action and Finder launcher.

### Task 4: Verification

- [ ] Run backend tests.
- [ ] Run Swift build.
- [ ] Run `script/build_and_run.sh --verify`.
- [ ] Open the fresh app and verify backend reaches ready state.
- [ ] Optionally run a short audio separation after a model downloads.
