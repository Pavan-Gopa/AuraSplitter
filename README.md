# KirtanSplitter

Native macOS app for separating noisy live kirtan recordings into stems with
UVR-compatible models running through `mlx-audio-separator` on Apple Silicon
MLX/Metal.

## What Works

- Drag-and-drop or file picker audio input.
- Local Python backend launched by the SwiftUI app.
- MLX/Metal acceleration through `mlx-audio-separator`.
- Presets for:
  - `Kirtan Pro`: `BS-Roformer-SW.ckpt` 6-stem split.
  - `Clean Vocal / Instrumental`: `model_bs_roformer_ep_368_sdr_12.9628.ckpt`.
  - `Instrument Bleed Control`: `mel_band_roformer_instrumental_instv7n_gabox.ckpt`.
  - `Drums / No Drums`: `kuielab_a_drums.onnx`.
- Model picker with the live model catalog exposed by the backend.
- Local model cache in `models/`.
- Output stems in FLAC or WAV.
- Finder reveal, path copy, and audio preview for generated stems.
- Right-side diagnostics inspector:
  - live process stage and progress,
  - system CPU and memory,
  - backend PID / CPU / RSS memory,
  - MLX GPU device and GPU telemetry status,
  - cached checkpoints and converted `.safetensors`,
  - last-run decode / inference / write timings.

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

`script/build_and_run.sh` always stops a previous `KirtanSplitter` process,
builds a fresh SwiftPM binary, stages `dist/KirtanSplitter.app`, and opens that
fresh bundle.

## Diagnostics Notes

CPU, memory, backend RSS, model cache, converted safetensors, and separation
timings are collected directly from the local backend and system tools. GPU
device detection is real through MLX. Detailed GPU utilization/power depends on
macOS `powermetrics`; if the OS denies access without elevated privileges, the
GPU widget shows that status instead of inventing a number.

## Tests

```bash
./script/test_backend.sh
swift build
```

The backend tests use a fake engine, so they do not download models.

## Runtime Data

- `.venv/`: local Python 3.11 environment.
- `models/`: downloaded UVR model files and converted safetensors.
- `dist/`: staged local app bundle.
- Output stems: selected output folder, or `<input>_stems` next to the input.

These paths are intentionally ignored by git.

## Notes

The previous hand-written `bsroformer_mlx.py` prototype is still preserved under
`KirtanSplitter/` for reference, but it is not used by the production path. The
working path uses `mlx-audio-separator`, which already supports RoFormer, MDXC,
MDX, VR, and Demucs models on MLX.
