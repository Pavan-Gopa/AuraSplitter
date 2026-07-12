# FEEDBACK — OPT_PERF closed

## Track status
**OPT_PERF = DONE** (K0–K8 all approved).

| Step | Tag |
|------|-----|
| K0 | opt/K0-done |
| K1 | opt/K1-done |
| K2 | opt/K2-done |
| K3 | opt/K3-done |
| K4 | opt/K4-done |
| K5 | opt/K5-done |
| K6 | opt/K6-done |
| K7 | opt/K7-done |
| K8 | opt/K8-done |

## Last step: K8 — APPROVED (Gemini)

- MLX Metal memory/cache limits + env overrides
- Static RAM batch heuristic (no cold auto_tune)
- Preview LRU + disk cache (SHA256 key, 20 / 256MB)
- Tests green (91 Python / 56 Swift per review)

## No pending review

Post-OPT only if human asks (CoreML ONNX/ANE, colormap LUT, metal waveform).
Optional: measure and fill PERF_BASELINE.md **after** column on real hardware.
