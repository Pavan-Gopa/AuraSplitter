#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UV_BIN="${UV_BIN:-/Users/pavan/.local/bin/uv}"

if [[ ! -x "$UV_BIN" ]]; then
  if command -v uv >/dev/null 2>&1; then
    UV_BIN="$(command -v uv)"
  else
    echo "uv is required. Install it with: brew install uv" >&2
    exit 1
  fi
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "ffmpeg is required for audio decoding/encoding. Install it with: brew install ffmpeg" >&2
  exit 1
fi

cd "$ROOT_DIR"
"$UV_BIN" python install 3.11
if [[ ! -x ".venv/bin/python" ]]; then
  "$UV_BIN" venv --python 3.11 .venv
fi
"$UV_BIN" pip install --python .venv/bin/python -r requirements.txt

PYTHONPATH="$ROOT_DIR/backend" .venv/bin/python - <<'PY'
import mlx.core as mx
import mlx_audio_separator
from kirtan_backend.engine import MlxSeparatorEngine

engine = MlxSeparatorEngine(model_dir="models")
print("MLX device:", mx.default_device())
print("mlx-audio-separator:", getattr(mlx_audio_separator, "__version__", "unknown"))
print("model_dir:", engine.model_dir)
PY
