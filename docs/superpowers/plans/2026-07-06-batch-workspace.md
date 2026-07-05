# Batch Workspace Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the current single-file center workspace into a batch-capable workspace where sources and result stems can be previewed in the waveform/spectrogram pane, stems can be deleted from disk, and selected sources process top-to-bottom.

**Architecture:** Keep the Python backend unchanged for separation and analysis. Add small Swift batch models for source rows, result groups, folder scanning, and file deletion, then make `ContentView` coordinate analysis, preview target selection, and sequential batch runs. Keep the first batch implementation intentionally local: one output settings panel, per-source preset picker, global model override.

**Tech Stack:** SwiftPM, SwiftUI, AVFoundation, FileManager, existing Python backend JSON protocol.

---

### Task 1: Batch Workspace Models

**Files:**
- Modify: `Package.swift`
- Create: `Sources/KirtanSplitterApp/Models/BatchWorkspaceModels.swift`
- Create: `tests/KirtanSplitterAppTests/BatchWorkspaceTests.swift`

- [x] Add SwiftPM test target.
- [x] Add failing tests for first-level audio folder scan, nested-folder ignore, source item defaults, and result-stem deletion.
- [x] Implement focused batch models and helpers.
- [x] Run `swift test`.

### Task 2: Source And Result UI

**Files:**
- Modify: `Sources/KirtanSplitterApp/Views/ControlPaneView.swift`
- Modify: `Sources/KirtanSplitterApp/Views/SourceResultOverviewView.swift`
- Modify: `Sources/KirtanSplitterApp/Views/ContentView.swift`

- [x] Add folder picker under the drop zone.
- [x] Render source rows with process checkbox, preview click, metadata, and per-source preset picker.
- [x] Render result groups separated by source file.
- [x] Add result stem selection and delete action.

### Task 3: Sequential Batch Processing

**Files:**
- Modify: `Sources/KirtanSplitterApp/Views/ContentView.swift`
- Modify: `Sources/KirtanSplitterApp/Views/ControlPaneView.swift`

- [x] Replace single run action with top-to-bottom selected source processing.
- [x] Keep single-file flow as a one-item batch.
- [x] Store each source result in its own group.
- [x] Keep bottom preview target synced to clicked source or result.

### Task 4: Verification

**Files:**
- Modify: `README.md`

- [x] Update docs.
- [x] Run `swift test`.
- [x] Run `./script/test_backend.sh`.
- [x] Run `swift build`.
- [x] Run `git diff --check`.
- [x] Run `./script/build_and_run.sh --verify`.
- [x] Smoke-check UI layout with a screenshot.
