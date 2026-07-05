# Audio Preview And Mono Output Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preserve mono source channel layout in separated stems and add a professional center preview surface with source/result columns plus waveform/spectrogram playback.

**Architecture:** The backend remains responsible for audio inspection because it already depends on `ffmpeg` and Python numeric tooling. Swift gets compact audio analysis data and renders it with native `Canvas`; playback stays local through `AVAudioPlayer`. The first preview version is diagnostic, not an editor: duration, channel count, peak level, clipping warning, waveform, spectrogram, seek, and playhead.

**Tech Stack:** Python backend, pytest, ffmpeg/ffprobe, NumPy, SwiftUI Canvas, AVFoundation, SwiftPM.

---

### Task 1: Mono Output Preservation

**Files:**
- Modify: `backend/kirtan_backend/engine.py`
- Test: `tests/test_backend_protocol.py`

- [x] Add a failing test where mono input is prepared as stereo for MLX but output stems are restored to mono.
- [x] Implement output downmix only when the source channel count is one.
- [x] Verify stereo input is not downmixed.

### Task 2: Audio Analysis API

**Files:**
- Create: `backend/kirtan_backend/audio_analysis.py`
- Modify: `backend/kirtan_backend/engine.py`
- Modify: `backend/kirtan_backend/protocol.py`
- Test: `tests/test_backend_protocol.py`

- [x] Add a failing protocol test for `analyze_audio`.
- [x] Decode compact mono preview samples through ffmpeg.
- [x] Return duration, channels, sample rate, max dBFS, clipping flag, waveform peaks, and spectrogram values.

### Task 3: Swift Preview Models And Client

**Files:**
- Create: `Sources/KirtanSplitterApp/Models/AudioAnalysisModels.swift`
- Modify: `Sources/KirtanSplitterApp/Services/BackendClient.swift`
- Modify: `Sources/KirtanSplitterApp/Support/FileHelpers.swift`

- [x] Decode backend audio analysis.
- [x] Add async `analyzeAudio(url:)`.
- [x] Add preview playback player with current-time seeking.

### Task 4: Center Layout And Preview UI

**Files:**
- Modify: `Sources/KirtanSplitterApp/Views/ContentView.swift`
- Create: `Sources/KirtanSplitterApp/Views/AudioPreviewPane.swift`
- Create: `Sources/KirtanSplitterApp/Views/SourceResultOverviewView.swift`

- [x] Split center content into top source/result columns and bottom preview occupying about 38% height.
- [x] Render waveform/spectrogram with clipping-aware color.
- [x] Add play/pause, click/drag seek, and playhead.

### Task 5: Verification

**Files:**
- Modify: `README.md`

- [x] Update docs.
- [x] Run `./script/test_backend.sh`.
- [x] Run `swift build`.
- [x] Run `./script/build_and_run.sh --verify`.
- [x] Smoke-check audio analysis against an existing file.
