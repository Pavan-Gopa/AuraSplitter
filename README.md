# KirtanSplitter

Native macOS app for separating noisy live kirtan recordings into stems with
UVR-compatible models running through `mlx-audio-separator` on Apple Silicon
MLX/Metal.

## What Works

- Batch-first source queue from drag-and-drop, file picker, or folder picker.
  Folder loading imports only first-level audio files and ignores nested folders.
- Local Python backend launched by the SwiftUI app.
- MLX/Metal acceleration through `mlx-audio-separator`.
- Presets for:
  - `Kirtan Pro`: `BS-Roformer-SW.ckpt` 6-stem split.
  - `Kirtan Clean Split`: ViperX 1297 vocal / instrumental split.
  - `Kirtan Vocal Classic`: ViperX 1296 vocal / instrumental split.
  - `Kirtan Karaoke Classic`: ViperX karaoke-style split.
  - `Kirtan Instrument Clean`: instrumental cleanup when vocal bleed remains.
  - `Kirtan Drum Classic`: classic drums / no-drums split.
  - Model Pack V1 presets that download public checkpoints on first use:
    `Kirtan Vocal Pro`, `Kirtan Instrument Pro`, `Kirtan Vocal Elite`,
    `Kirtan Instrument Elite`, `Kirtan Vocal / Instrumental`,
    `Kirtan Lead / Back`, `Kirtan Lead / Back 2`, `Kirtan Drum Split`,
    and selected MVSep Mega 53 single-target
    models for lead vocal, back vocal, drums, sitar, and piano.
  - ONNX/CoreML presets:
    `Kirtan Vocal Max` for BS PolarFormer vocal / instrumental separation,
    `Kirtan Stems Pro` for vocals, drums, bass, and other, and
    `Kirtan Stems Max` for vocals, drums, bass, guitar, piano, and other.
- Model picker with the full live model catalog exposed by the backend, using
  simple Kirtan-facing names. Technical checkpoint names are kept in the
  diagnostics sidebar metadata instead of the header picker.
- Kirtan model-pack catalog layered over `mlx-audio-separator` without patching
  site-packages. The backend downloads a preset's checkpoint plus YAML config
  into the local model cache before first MLX conversion.
- Runtime model cache in `~/AI_LOCAL_MODELS/Sound/KirtanSplitter/`, with a
  one-time sync from the previous Application Support cache when present.
- Output stems in FLAC or WAV.
- Header-level run controls with a fixed Start / Cancel / Restart button,
  model preset picker, process-settings preset picker, and long progress meter.
- Self-calibrating render-time estimate in the header. Completed runs are saved
  locally and reused to estimate the next run for the selected model, process
  preset, source duration, and GPU core count.
- UVR/MDXC controls for RoFormer models:
  - segment size up to 4096,
  - overlap,
  - batch size,
  - model segment override.
- Custom process-settings presets for output format, speed profile, chunk size,
  segment size, overlap, batch size, model segment override, and converted-model
  retention.
- Finder reveal, path copy, and audio preview for generated stems.
- Source preview with channel count, duration, sample rate, bit depth, model
  metadata for KirtanSplitter-generated files, peak dBFS, clipping warning,
  waveform, spectrogram, playhead, and click/drag seeking.
- Source rows include processing checkboxes and per-file preset selection.
- Separated results are grouped by source file. Clicking any generated stem
  loads that stem into the waveform/spectrogram preview, and stem rows can
  delete the generated audio file from disk.
- Source format preservation: MLX models can still receive a temporary
  stereo/float compatibility input, but generated stems are restored to the
  source channel count, sample rate, WAV bit depth, and WAV PCM codec family
  before saving. Output files also receive compact KirtanSplitter metadata with
  the model, checkpoint, model preset, and process preset.
- Right-side settings drawer:
  - `Process` tab for model and process settings,
  - `Models` tab with the visible model storage folder, installed model groups,
    and not-yet-downloaded model metadata,
  - `Last Run` tab with only the latest completed run: start/completion time,
    model, preset, process settings, timings, and output files,
  - `Logs` tab with a readable backend log console plus open, reveal, export,
    and clear actions.
- Compact left widgets show input count plus backend, CPU, memory, GPU, and model
  cache status while processing controls stay in the header.
- Header model menu marks locally cached models with a green dot and shows a
  compact personal usage count from completed runs.

## Requirements

- Apple Silicon Mac.
- macOS 13+.
- Xcode command-line tools / SwiftPM.
- `uv` for Python 3.11 environment management.
- `ffmpeg` for audio decoding/encoding.
- `torch` is installed into `.venv` only so `.ckpt` RoFormer models can be
  converted to MLX safetensors on first use. Inference is still MLX/Metal.
- `demucs-onnx` and `onnxruntime` are installed for the optional ONNX/CoreML
  presets. Demucs uses its own local cache under the KirtanSplitter model
  folder; PolarFormer downloads its ONNX model and YAML config into the same
  visible model folder as the other KirtanSplitter models.

Install external tools:

```bash
brew install uv ffmpeg
```

## Run

From this folder:

```bash
./script/setup_backend.sh
./script/build_and_run.sh
```

Finder launcher:

```bash
open "Launch KirtanSplitter.command"
```

`script/build_and_run.sh` always stops previous `KirtanSplitter` and backend
processes, builds a fresh SwiftPM binary, stages `dist/KirtanSplitter.app`,
starts the local Python backend on `127.0.0.1:51273`, then opens the fresh
bundle. The backend is started by the shell script instead of by the `.app`
itself; this avoids a macOS LaunchServices child-process stall seen when a
bundle-opened app starts Python directly.

## Diagnostics Notes

CPU, memory, backend RSS, model cache, converted safetensors, and separation
timings are collected directly from the local backend and system tools. GPU
device detection is real through MLX. GPU utilization and GPU core count fall
back to macOS `ioreg` when `powermetrics` is unavailable without elevated
privileges. GPU power still depends on `powermetrics`; if the OS denies access,
the GPU widget shows utilization without inventing power data.

ONNX/CoreML presets request Core ML with `MLComputeUnits=ALL`, which allows
Core ML to schedule supported operators across CPU, GPU, and Neural Engine.
The NPU widget reports this CoreML/Neural Engine availability mode; macOS does
not provide a stable public per-process Neural Engine utilization percentage
that can be shown as honestly as CPU or GPU usage.

`Speed` is a runtime profile passed to `mlx-audio-separator`, not an output
quality preset. `default` leaves the library defaults untouched, `latency_safe`
uses conservative batch sizes for lower peak memory, and `latency_safe_v3` adds
deferred cache clearing plus two write workers for long FLAC/WAV runs.

Persistent backend logs are written to:

```text
~/Library/Application Support/KirtanSplitter/logs/backend.log
```

The log contains backend startup, action requests, progress events, model load
activity, conversion messages, and any uncaught exceptions from the Python
server. Routine telemetry polls such as `runtime_stats`, `model_cache`, and
`ping` are intentionally not written to the persistent log.

## Render Benchmarks

Every successful separation records a local calibration sample in:

```text
~/AI_LOCAL_MODELS/Sound/KirtanSplitter/render_benchmarks.json
```

To deliberately benchmark one kirtan track across model presets and the
`Fast 512`, `Heavy 1024`, and `Extreme 4096` process presets:

```bash
./script/benchmark_models.py /path/to/kirtan.wav --presets all --process-presets builtin.fast,builtin.heavy,builtin.extreme
```

This can take many hours and may download model files, so run it only on a
track you intentionally choose for calibration.

## Tests

```bash
./script/test_backend.sh
swift build
```

The backend tests use a fake engine, so they do not download models.

## Runtime Data

- `.venv/`: local Python 3.11 environment.
- `models/`: project-side seed cache copied into the user-visible runtime cache when present.
- `~/AI_LOCAL_MODELS/Sound/KirtanSplitter/`: runtime UVR model files, converted safetensors, ONNX cache, and render benchmark history.
- `~/Library/Application Support/KirtanSplitter/models/`: legacy runtime model cache; copied into the new user-visible folder when present.
- `~/Library/Application Support/KirtanSplitter/logs/backend.log`: backend startup, progress, and error log.
- `dist/`: staged local app bundle.
- Output stems: selected output folder, or `<input>_stems` next to the input.

These paths are intentionally ignored by git.

After the first successful MLX conversion, the app groups a model's source
checkpoint, converted `.safetensors`, and YAML config as one installed model.
The diagnostics UI hides YAML config files as separate rows. Deleting a source
checkpoint for an installed model keeps the `.safetensors` and YAML config, and
replaces the large source file with a tiny placeholder so the upstream loader
does not re-download it before loading the converted weights.

## Notes

The previous hand-written `bsroformer_mlx.py` prototype is still preserved under
`KirtanSplitter/` for reference, but it is not used by the production path. The
working path uses `mlx-audio-separator`, which already supports RoFormer, MDXC,
MDX, VR, and Demucs models on MLX.

## Model Architecture Notes

Model Pack V1 exposes MLX-compatible models through `mlx-audio-separator`:
BS-RoFormer, MelBand RoFormer, and MDX23C/MDXC-style checkpoints with YAML
configs. It also adds separate ONNX/CoreML backends for Demucs ONNX models via
`demucs-onnx` and BS PolarFormer via a model-specific STFT/ONNX/iSTFT adapter.
Those presets are routed outside MLX and use ONNX Runtime provider selection,
which can choose CoreML on Apple Silicon when the runtime supports it.
PolarFormer uses a dedicated CoreML cache under the visible model folder and
reports real chunk-level progress instead of a synthetic long-running heartbeat.

Generic ONNX files are not interchangeable: each one can require different audio
windowing, spectrogram inputs, and postprocessing. DrumSep ONNX remains
cataloged as an experimental candidate until it has its own adapter.
