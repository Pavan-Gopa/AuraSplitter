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

## Current track: DESIGN_V2

UI/UX + branding. Cards: `AI_Workflow_Kit/docs/DESIGN_STEPS.md`. Gates: Gemini review **and** live visual accept.

| Step | Name |
|------|------|
| D0 | Branding AuraSplitter + logo + Kirtan→Aura titles |
| D1 | Process preset → Custom when dirty |
| D2 | Results: Compare menu; Info→Folder→Trash |
| D3 | Settings sidebar reorder / simplify |
| D4 | Eye visibility models + process presets |
| D5 | Est. time from real knobs |
| D6 | Filled waveform + main Spectrum/Waveform sliders |
| DESIGN_DONE | Acceptance |

Post-OPT (CoreML ONNX/ANE runner, etc.) is **out of scope** until OPT is accepted.

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
From repo root `KirtanSplitter/`:
- Plan: `OPTIMIZATION_PLAN_GROK.md`
- Steps: `AI_Workflow_Kit/docs/OPT_STEPS.md`
- State: `AI_Workflow_Kit/docs/AI/STATE.yaml`
- Feedback: `AI_Workflow_Kit/docs/AI/FEEDBACK.md`
