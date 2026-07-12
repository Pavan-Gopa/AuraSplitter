# OPT_PERF — пошаговый план для агентов

> **Источник истины для scope:** корневой [`OPTIMIZATION_PLAN_GROK.md`](../../OPTIMIZATION_PLAN_GROK.md)  
> **Референс-псевдокод:** [`OPTIMIZATION_PLAN.md`](../../OPTIMIZATION_PLAN.md) (Claude)  
> **Этот файл:** нумерованные шаги для `STATE.yaml` → `current_step`  
> **Post-OPT не трогать**, пока OPT не accepted.

## Роли (напоминание)

| Роль | Модель | Действие |
|------|--------|----------|
| Orchestrator | Grok | `STATE.yaml`, конфликты, next step, **git pre/post checkpoints** |
| Implementation Engineer | **Hy3 / Hi3** | код только в `target_files` (требует `opt/pre-Kn`) |
| Verification Engineer | **Gemini 3.5 Flash** | `FEEDBACK.md` + `review.status` |

## Git (каждый шаг)

```bash
./script/opt_checkpoint.sh pre  Kn          # ДО реализации
./script/opt_checkpoint.sh post Kn "…"    # ПОСЛЕ approve
```

Tags: `opt/pre-Kn`, `opt/Kn-done`. Docs: `AI_Workflow_Kit/docs/AI/GIT_CHECKPOINTS.md`.

---

## Шаги OPT

| `current_step` | Название | Цель |
|----------------|----------|------|
| **K0** | Baseline & harness | Измеримость «до» |
| **K1** | MLX flags + Metal presets | Experimental kernels + presets |
| **K2** | ffprobe + row-major | I/O + texture layout |
| **K3** | Warm Separator cache | Skip reload on 2nd track |
| **K4** | Binary ksbin + mmap | Cut mega-JSON |
| **K5** | Progressive preview | RX-style first paint |
| **K6** | Design tokens + chrome | KSTheme, quieter UI |
| **K7** | vDSP local analysis | On-device FFT path |
| **K8** | Memory + batch heuristic + LRU | Metal limits, no cold auto_tune |
| **OPT_DONE** | Приёмка | gates green |

```text
K0 baseline → K1 Metal flags → K2 I/O/layout → K3 warm cache
  → K4 binary → K5 progressive → K6 design → K7 vDSP → K8 memory → ✅ OPT done
```

---

## K0 — Baseline & harness

### Цель
Появилась возможность **измерить** скорость separation и preview **до** оптимизаций. Без изменения поведения.

### Требования
1. Создать корневой `PERF_BASELINE.md`:
   - как запустить `.venv/bin/pytest tests/ -q`
   - как `swift build` / `swift test`
   - как `script/benchmark_models.py` (если применимо) — флаги/пример
   - таблица сценариев с колонкой **до** (заполнить числом если замер возможен, иначе `TODO`):
     - Separate 1 track (named model/preset)
     - Separate 2nd track **same model** (expect later warm-cache win)
     - `analyze_audio` on ~5 min file (or shorter fixture)
2. Не менять engine / UI / protocol behavior.
3. Verify: pytest still passes; swift build still passes (no required code change if docs-only).

### Не делать
- Experimental flags, warm cache, binary protocol, design tokens

### target_files (ориентир)
- `PERF_BASELINE.md` (NEW)
- optionally tiny comment/help in `script/benchmark_models.py` **only if** needed for baseline docs

### Done
- PERF_BASELINE.md exists with commands + table
- no product behavior change
- tests/build green

---

## K1 — MLX experimental flags + Metal presets

### Цель
Вынести experimental performance flags из hardcode; добавить process presets **Metal Fast** / **Metal Max**; benchmark path.

### Требования
См. `OPTIMIZATION_PLAN_GROK.md` §1.1. Кратко:
1. `SeparationJob` / params несут performance flags (не hardcode `False` only).
2. Presets: Metal Fast (safe experimental set) / Metal Max (compile + fallback).
3. **`auto_tune_batch` default OFF** on these presets (no 8s hang).
4. Wire into Swift process preset store / ControlPane if presets are user-visible.
5. `script/benchmark_models.py` can exercise new flags or document how.
6. pytest for job/presets; swift build if Swift touched.

### Не делать
- Warm cache (K3), binary preview (K4), auto_tune cold path

### target_files (ориентир)
- `backend/kirtan_backend/engine.py`
- `backend/kirtan_backend/jobs.py`
- `backend/kirtan_backend/process_presets.py`
- `Sources/KirtanSplitterApp/Models/ProcessSettingsPreset.swift`
- `Sources/KirtanSplitterApp/Models/BackendModels.swift`
- `Sources/KirtanSplitterApp/Views/ControlPaneView.swift` (if needed)
- `tests/test_process_presets.py` and/or protocol tests
- related Swift tests if present
- `script/benchmark_models.py` (optional)

### Done
- Flags configurable; Metal presets exist; auto_tune not default-on; tests pass

---

## K2 — Single ffprobe + row-major spectrogram

### Цель
Один ffprobe на source format; spectrogram layout row-major → no CPU transpose on texture upload.

### Требования
1. `_source_audio_format` (or equivalent) — **one** ffprobe JSON, not 4 probes.
2. Backend spectrogram values layout documented as row-major (bin rows) matching Metal texture.
3. Swift `MetalSpectrogramTexturePayload` — remove O(N) transpose if layout matches.
4. Tests for analysis layout / format probe.

### Не делать
- Binary protocol (K4), progressive (K5)

### target_files (ориентир)
- `backend/kirtan_backend/engine.py`
- `backend/kirtan_backend/audio_analysis.py`
- `Sources/KirtanSplitterApp/Models/MetalSpectrogramTexturePayload.swift`
- `tests/test_audio_analysis.py`
- Metal texture tests if any

### Done
- Single probe; no transpose path (or justified residual); tests pass

---

## K3 — Warm Separator cache

### Цель
Не пересоздавать/не перезагружать модель на каждый `separate` при том же fingerprint.

### Требования
См. pseudocode in `OPTIMIZATION_PLAN_GROK.md` §1.2:
1. `_cached_separator` + model filename + fingerprint (segment/batch/speed/perf).
2. Invalidate on model change / OOM / cancel restart as appropriate.
3. Runtime/UI: optional `modelHot` signal.
4. Unit/fake-engine tests for hit/miss.

### Не делать
- Binary preview, progressive, CoreML

### target_files (ориентир)
- `backend/kirtan_backend/engine.py`
- `backend/kirtan_backend/runtime.py` (if stats)
- protocol/tests for cache indicator if exposed
- Swift widget only if `modelHot` wired this step

### Done
- Second separate same model skips full reload path; tests pass

---

## K4 — Binary ksbin + mmap client

### Цель
Перестать тащить ~1.8M doubles as JSON text.

### Требования
См. Claude/Grok binary format:
1. Backend writes `.ksbin` (header + float32 wave + float32 row-major spec).
2. JSON result: metadata + `binaryPayloadPath`.
3. Swift mmap/read, delete temp file, fill `AudioAnalysis`.
4. Round-trip tests.

### Не делать
- Progressive multi-phase (K5) beyond single full binary response is OK to stay one-shot

### target_files (ориентир)
- `backend/kirtan_backend/audio_analysis.py`
- `backend/kirtan_backend/protocol.py`
- `Sources/KirtanSplitterApp/Services/BackendClient.swift`
- `Sources/KirtanSplitterApp/Models/AudioAnalysisModels.swift`
- tests Python + Swift

### Done
- Analyze path uses binary payload; tests pass; no mega JSON values array in happy path

---

## K5 — Progressive preview protocol

### Цель
First paint waveform &lt;300ms feel; spectrogram fills progressively.

### Требования
1. Phases: waveform_preview → waveform_full → spectrogram_chunk(s) (or low-res then HQ).
2. Protocol progress events; Swift UI updates incrementally + shimmer/loading.
3. Do not block UI on full HQ before first paint.

### Не делать
- Full vDSP rewrite (K7) unless needed as helper

### target_files (ориентир)
- `backend/kirtan_backend/audio_analysis.py`
- `backend/kirtan_backend/protocol.py`
- `Sources/KirtanSplitterApp/Services/BackendClient.swift`
- `Sources/KirtanSplitterApp/Views/AudioPreviewPane.swift`
- `Sources/KirtanSplitterApp/Models/AudioPreviewAnalysisCache.swift` (if needed)
- tests

### Done
- Progressive events work; UI paints early; tests for phase order

---

## K6 — Design tokens + chrome pass

### Цель
`KSTheme` / `DesignTokens.swift`; quieter minimal UI; shared colors.

### Требования
1. New `DesignTokens.swift` (`KSTheme`) with colors/spacing/radii.
2. Replace hardcoded RGB in main chrome: ContentView header, rail, preview frame, key list rows.
3. Loading shimmer or clearer analyzing state if cheap.
4. No functional separation changes.

### Не делать
- Full app redesign; vDSP; CoreML

### target_files (ориентир)
- `Sources/KirtanSplitterApp/Models/DesignTokens.swift` (NEW)
- `Sources/KirtanSplitterApp/Views/ContentView.swift`
- `Sources/KirtanSplitterApp/Views/WorkspaceWidgetRailView.swift`
- `Sources/KirtanSplitterApp/Views/AudioPreviewPane.swift`
- `Sources/KirtanSplitterApp/Views/SourceResultOverviewView.swift` (if in scope)
- swift build

### Done
- Theme file exists; main views use tokens; build green

---

## K7 — vDSP local analysis (or hybrid)

### Цель
On-device Accelerate FFT for typical tracks; fallback to backend binary for huge files optional.

### Требования
1. Swift path: decode PCM + vDSP STFT + peaks → Metal texture.
2. Hybrid policy documented (when local vs backend).
3. Quality comparable for preview (not bit-identical required).
4. Tests for peak/spec dimensions / smoke.

### Не делать
- Separation engine changes

### target_files (ориентир)
- new Swift analysis utilities under `Sources/KirtanSplitterApp/`
- `BackendClient` / ContentView wiring
- Metal upload path
- tests

### Done
- Local analysis works for fixture/short file; fallback policy clear

---

## K8 — Memory limits + static batch heuristic + LRU disk cache

### Цель
MLX metal memory/cache limits; RAM-based batch default; preview disk LRU. **No cold auto_tune.**

### Требования
1. `mx.metal.set_memory_limit` / `set_cache_limit` with env overrides.
2. Static batch heuristic by RAM (1/2/4) — not 8s probe on Separate.
3. Preview analysis cache: LRU + disk under Application Support/Caches.
4. Tests for heuristic + cache eviction if unit-testable.

### Не делать
- Enable auto_tune by default

### target_files (ориентир)
- `backend/kirtan_backend/engine.py` / `runtime.py` / `jobs.py`
- `Sources/KirtanSplitterApp/Models/AudioPreviewAnalysisCache.swift`
- related Swift disk cache helper (NEW)
- tests

### Done
- Limits applied; batch heuristic documented; LRU disk works; no cold auto_tune

---

## OPT_DONE — Acceptance

### Цель
Закрыть track.

### Требования
1. K0–K8 in `completed_steps`.
2. `PERF_BASELINE.md` updated with **after** column where measured.
3. Orchestrator sets `next_actor: human`, `implementation.status: idle`.

### Post-OPT backlog (only if human asks)
- CoreML ONNX/ANE runner
- Colormap LUT pack
- Metal waveform renderer
