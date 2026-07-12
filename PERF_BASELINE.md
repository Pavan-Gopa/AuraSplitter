# PERF_BASELINE.md — K0 Baseline & Harness

OPT_PERF track, step **K0**. This file establishes **measured "до" (before)**
numbers so later optimization steps (K1–K8) have a comparison baseline.

> Scope of K0: only measurement + harness. No engine / UI / protocol behavior
> changes. The `до` column is filled where a measurement was feasible in this
> pass; otherwise it is `TODO` with the exact command to fill it later.

## Environment (fill once on each machine)

| Field | Value |
|-------|-------|
| Machine | Apple Silicon Mac (fill in: model / chip) |
| macOS | 13+ (fill in exact) |
| GPU cores | (fill in — affects MLX; see `runtime_stats` `gpu.gpuCoreCount`) |
| Python | `.venv` (Python 3.11 via `uv`) |
| Backend | `mlx-audio-separator==0.1.5` on MLX/Metal |

## Verify commands

### Python backend tests

`kirtan_backend` is only importable when `backend/` is on `PYTHONPATH`
(the project's `script/test_backend.sh` sets this). From the repo root:

```bash
# Preferred (sets PYTHONPATH for you):
./script/test_backend.sh

# Equivalent direct form:
PYTHONPATH=backend .venv/bin/pytest tests/ -q
```

Result this pass: **66 passed in ~2.0s** (uses a fake engine; no model
downloads).

### Swift app build / tests

```bash
swift build          # builds the KirtanSplitterApp executable
swift test           # runs tests/KirtanSplitterAppTests (if present)
```

Result this pass: **`swift build` succeeds** (cached, ~0.1s when unchanged).

### Model separation benchmark harness

`script/benchmark_models.py` runs one audio file across model presets and
process presets, writing `benchmark_results.jsonl`. It self-re-execs under
`.venv/bin/python`.

```bash
# All model presets × Fast/Heavy/Extreme process presets (can take HOURS,
# downloads models on first use):
./script/benchmark_models.py /path/to/kirtan.wav \
    --presets all \
    --process-presets builtin.fast,builtin.heavy,builtin.extreme

# One preset × one process preset (faster):
./script/benchmark_models.py /path/to/kirtan.wav \
    --presets kirtan_pro \
    --process-presets builtin.fast

# Flags
#   input                  positional: audio file to benchmark
#   --output-dir DIR       results dir (default: ~/Library/Application Support/.../benchmarks/<ts>)
#   --model-dir DIR        model cache dir (default: ~/AI_LOCAL_MODELS/Sound/KirtanSplitter)
#   --presets LIST         comma list or "all"
#   --process-presets LIST comma list (builtin.fast|builtin.heavy|builtin.extreme)
#   --stop-on-error        abort on first failed model
```

Each output row in `benchmark_results.jsonl` has `status`, `elapsedSeconds`,
`modelPresetID`, `processPresetID`, and `outputDir` — use `elapsedSeconds` for
the baseline table below.

## Baseline timing table (до / before)

Scenario naming uses a concrete model + preset so the measurement is
reproducible.

| # | Scenario | Model / preset | Command to measure | **до (before)** |
|---|----------|----------------|--------------------|------------------|
| 1 | Separate 1 track (cold cache) | `kirtan_pro` / `BS-Roformer-SW.ckpt` (builtin.fast) | `./script/benchmark_models.py <5min file> --presets kirtan_pro --process-presets builtin.fast` | `TODO` |
| 2 | Separate 2nd track **same model** (warm cache, expect later K3 win) | `kirtan_pro` / `BS-Roformer-SW.ckpt` (builtin.fast) | re-run scenario 1 on a 2nd file; compare `elapsedSeconds` | `TODO` |
| 3 | `analyze_audio` on a 5 min file | fixture 300s / 44.1kHz stereo | `from kirtan_backend.audio_analysis import analyze_audio` (waveform 8192, spectrogram 8192×224) | **0.57 s** (measured on 300s fixture, M-series) |
| 3b | `analyze_audio` on a 30 s file (smaller fixture) | fixture 30s / 44.1kHz stereo | same as 3 | **0.40 s** (measured on 30s fixture, M-series) |

### Notes on the measured `analyze_audio` numbers

Measured with synthetic `sine` fixtures decoded to mono float @ 22050 Hz by
`audio_analysis.analyze_audio`:

- 30 s fixture → **0.403 s**
- 300 s fixture → **0.569 s**

The cost is dominated by ffmpeg decode + the per-column STFT loop in
`audio_analysis._spectrogram` (8192 columns × 224 bins = 1,835,008 floats). It
scales sub-linearly with duration because most time is fixed decode/setup
overhead. K2/K5/K7 are expected to move this number.

### K7 — local-first hybrid policy

`BackendClient.analyzeAudio` now checks `LocalAudioAnalyzer.canAnalyzeLocally`
before hitting the backend. If the source file is **≤ 200 MB** it runs fully
on-device via Accelerate/vDSP (`LocalAudioAnalyzer.analyze`): decode PCM → mono
mix → vDSP FFT radix2 STFT → log-normalize into the same `SpectrogramData`
(row-major bin rows) and `AudioAnalysis` shape the backend produces. This
removes the Python round-trip for typical tracks (RX-class preview).

**Fallback:** files **> 200 MB** (or any local-analysis failure) fall through to
the existing backend progressive path (`analyze_audio` with ksbin binary
payload), so huge/atypical files keep working. No separation-engine or backend
MLX changes were made in K7.

Expected effect: preview `analyze_audio` latency for typical tracks drops to
~0 (local), leaving only the huge-file backend path in the `TODO` Separate
rows above unchanged.

### How to fill the `TODO` Separate rows

Run scenario 1 once (downloads the model on first use, then separates). Copy
`elapsedSeconds` into row 1. Immediately run scenario 2 on a second file of the
same duration — copy its `elapsedSeconds` into row 2. The gap between rows 1 and
2 is the cold-vs-warm model-load cost that K3 (warm Separator cache) targets.

> Do **not** enable experimental MLX flags or warm cache for the baseline
> measurement — K0 must capture un-optimized behavior.
