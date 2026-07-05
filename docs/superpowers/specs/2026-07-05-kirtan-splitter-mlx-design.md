# KirtanSplitter MLX Design

## Goal

Build a usable local macOS app for separating noisy live kirtan recordings into
stems with Apple Silicon GPU acceleration.

## Architecture

The app uses a native SwiftUI frontend and a local Python JSON-lines backend.
Swift owns file selection, settings, progress display, and result preview. Python
owns model discovery, model download/cache, and MLX separation.

The production backend uses `mlx-audio-separator` instead of the legacy
hand-written `bsroformer_mlx.py` prototype. That avoids relying on an incomplete
model port and keeps compatibility with the current UVR/RoFormer model catalog.

## Runtime Flow

1. `script/build_and_run.sh` builds the SwiftPM executable and stages
   `dist/KirtanSplitter.app`.
2. The app starts `.venv/bin/python backend/server.py`.
3. Swift sends JSON requests over stdin and reads JSON events over stdout.
4. Python loads/caches the selected model in `models/`.
5. Python writes stems to the selected output directory and returns file paths.

## Presets

- `kirtan_pro`: `BS-Roformer-SW.ckpt`.
- `vocal_clean`: `model_bs_roformer_ep_368_sdr_12.9628.ckpt`.
- `instrument_bleed`: `mel_band_roformer_instrumental_instv7n_gabox.ckpt`.
- `drum_focus`: `kuielab_a_drums.onnx`.

## Validation

Backend protocol tests run against a fake engine and do not download models.
Build validation uses `swift build`. Runtime validation uses
`script/build_and_run.sh --verify`.
