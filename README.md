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
  - `Clean Vocal / Instrumental`: `model_bs_roformer_ep_368_sdr_12.9628.ckpt`.
  - `ViperX Vocal 1296`: `BS-Roformer-Viperx-1296` alias for `model_bs_roformer_ep_368_sdr_12.9628.ckpt`.
  - `ViperX Karaoke Aufr33`: `MB-Ro-Kara-AuFR33-Viperx` alias for `mel_band_roformer_karaoke_aufr33_viperx_sdr_10.1956.ckpt`.
  - `Instrument Bleed Control`: `mel_band_roformer_instrumental_instv7n_gabox.ckpt`.
  - `Drums / No Drums`: `kuielab_a_drums.onnx`.
  - Model Pack V1 presets that download public checkpoints on first use:
    `HyperACE v2 Vocal`, `HyperACE v2 Instrumental`, `Leap Xe Vocal`,
    `Leap Xe Instrumental`, `Becruily Deux Vocal / Instrumental`,
    `Lead / Back BVE Gonza`, `Lead / Back Karaoke Anvuew`,
    `DrumSep MDX23C 5-Stem`, and selected MVSep Mega 53 single-target
    models for lead vocal, back vocal, drums, sitar, and piano.
- Model picker with the full live model catalog exposed by the backend, using
  UVR-friendly aliases for known ViperX names.
- Kirtan model-pack catalog layered over `mlx-audio-separator` without patching
  site-packages. The backend downloads a preset's checkpoint plus YAML config
  into the local model cache before first MLX conversion.
- Runtime model cache in `~/Library/Application Support/KirtanSplitter/models/`.
- Output stems in FLAC or WAV.
- Header-level run controls with a fixed Start / Cancel / Restart button,
  model preset picker, process-settings preset picker, and long progress meter.
- UVR/MDXC controls for RoFormer models:
  - segment size up to 4096,
  - overlap,
  - batch size,
  - model segment override.
- Custom process-settings presets for output format, speed profile, chunk size,
  segment size, overlap, batch size, model segment override, and converted-model
  retention.
- Finder reveal, path copy, and audio preview for generated stems.
- Source preview with channel count, duration, peak dBFS, clipping warning,
  waveform, spectrogram, playhead, and click/drag seeking.
- Source rows include processing checkboxes and per-file preset selection.
- Separated results are grouped by source file. Clicking any generated stem
  loads that stem into the waveform/spectrogram preview, and stem rows can
  delete the generated audio file from disk.
- Mono input preservation: MLX models can still receive a temporary stereo
  compatibility input, but stems are restored to mono when the source file is
  mono. Stereo sources stay stereo.
- Right-side diagnostics inspector:
  - persistent backend log path,
  - installed model groups backed by converted `.safetensors`,
  - confirmable source-checkpoint deletion after conversion,
  - last-run UVR parameters and decode / inference / write timings.
- Compact left widgets show input count plus backend, CPU, memory, GPU, and model
  cache status while processing controls stay in the header.

## Requirements

- Apple Silicon Mac.
- macOS 13+.
- Xcode command-line tools / SwiftPM.
- `uv` for Python 3.11 environment management.
- `ffmpeg` for audio decoding/encoding.
- `torch` is installed into `.venv` only so `.ckpt` RoFormer models can be
  converted to MLX safetensors on first use. Inference is still MLX/Metal.

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

`Speed` is a runtime profile passed to `mlx-audio-separator`, not an output
quality preset. `default` leaves the library defaults untouched, `latency_safe`
uses conservative batch sizes for lower peak memory, and `latency_safe_v3` adds
deferred cache clearing plus two write workers for long FLAC/WAV runs.

Persistent backend logs are written to:

```text
~/Library/Application Support/KirtanSplitter/logs/backend.log
```

The log contains backend startup, request methods, progress events, model load
activity, conversion messages, and any uncaught exceptions from the Python
server.

## Tests

```bash
./script/test_backend.sh
swift build
```

The backend tests use a fake engine, so they do not download models.

## Runtime Data

- `.venv/`: local Python 3.11 environment.
- `models/`: project-side cache copied into runtime cache when present.
- `~/Library/Application Support/KirtanSplitter/models/`: runtime UVR model files and converted safetensors.
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

Model Pack V1 only exposes models that can run through the current MLX backend:
BS-RoFormer, MelBand RoFormer, and MDX23C/MDXC-style checkpoints with YAML
configs. Experimental candidates such as BS PolarFormer and generic DrumSep ONNX
are cataloged in code but are intentionally not exposed as runnable presets yet.
They need one of two future backends:

- ONNX Runtime with CoreML Execution Provider for model-specific ONNX pipelines.
  This is the fastest route to support generic ONNX files, but performance and
  GPU/CoreML coverage depend on the model ops.
- A native MLX implementation for each architecture, such as PolarFormer/PoPE or
  newer DrumSep variants. This is the best long-term path for speed and a single
  MLX runtime, but it requires implementing each architecture's preprocessing,
  model graph, and postprocessing.
