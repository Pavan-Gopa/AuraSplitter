# Project Context — KirtanSplitter

## What this is
Native **macOS** app for stem separation of live kirtan recordings on **Apple Silicon**.

- **UI:** SwiftUI (`Sources/KirtanSplitterApp/`)
- **Backend:** Python JSON protocol (`backend/kirtan_backend/`)
- **Inference:** `mlx-audio-separator` → **MLX / Metal**
- **Preview:** Python analysis today; Metal spectrogram render; path toward binary/vDSP

## Workspace layout

| Path | Role |
|------|------|
| `Sources/KirtanSplitterApp/` | Swift app (views, models, BackendClient) |
| `backend/kirtan_backend/` | Engine, jobs, audio_analysis, protocol, presets |
| `models/` | Seed checkpoints |
| `script/` | setup, build_and_run, benchmark_models |
| `tests/` | pytest + Swift tests under `tests/KirtanSplitterAppTests/` |
| `OPTIMIZATION_PLAN_GROK.md` | **Main OPT plan** (Grok v3) |
| `OPTIMIZATION_PLAN.md` | Claude optimization plan (reference) |
| `AI_Workflow_Kit/` | Multi-agent orchestration (this kit) |
| `PERF_BASELINE.md` | Created in K0 — timings / how to measure |

## Display brand
**AuraSplitter** (UI title / marketing). Internal paths may still say KirtanSplitter until a later rebrand.

## Prior track: OPT_PERF (closed)

Faster model runs (Metal/MLX + memory), RX-class preview, design tokens. Tags: `opt/K0-done` … `opt/K8-done`.

## Prior track: DESIGN_V2 (closed)

UI/UX + branding. Historical cards: `AI_Workflow_Kit/docs/DESIGN_STEPS.md`.
All D0–D6 work is retained as completed history; it is not reopened by the
matrix fix.

## Current track: MATRIX_HARDENING

Automation Matrix interaction and keep/drop semantics. Canonical cards:
`AI_Workflow_Kit/docs/STEPS.md`. Standard pipeline: Coder → Main verification →
Reviewer → Main verification → Tester → Main verification.

| Step | Name |
|------|------|
| MATRIX_HARDENING | Matrix stem selection, click targets, and release 1.1.2 |

The matrix track preserves the existing separation engine and preset catalog.

## Rules
1. Keep project **testable** after every step (pytest / swift build).
2. Prefer **incremental** changes; only files in `STATE.yaml` → `target_files`.
3. Do **not** redesign architecture beyond the current step.
4. Do not implement later OPT steps early.
5. Agents communicate via `STATE.yaml` + `FEEDBACK.md` — human switches models.
6. **No** cold auto_tune on Separate; **no** metallib precompile.
7. **Git checkpoint before every step and after every approved step**  
   (`./script/opt_checkpoint.sh`, docs: `AI_Workflow_Kit/docs/AI/GIT_CHECKPOINTS.md`).  
   Tags: `opt/pre-Kn`, `opt/Kn-done` — rollback points on GitHub.

## Roles
- **Orchestrator** (Grok): prepares STATE, advances steps, deadlocks after 3 failed attempts
- **Implementation (Hy3 / Hi3)**: writes code
- **Verification (Gemini 3.5 Flash)**: reviews, writes FEEDBACK

## Paths note
From repo root `AuraSplitter/`:
- Plan: `AI_Workflow_Kit/docs/STEPS.md`
- Historical design plan: `AI_Workflow_Kit/docs/DESIGN_STEPS.md`
- State: `AI_Workflow_Kit/docs/AI/STATE.yaml`
- Feedback: `AI_Workflow_Kit/docs/AI/FEEDBACK.md`
