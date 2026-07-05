#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! -x "$ROOT_DIR/.venv/bin/python" ]]; then
  "$ROOT_DIR/script/setup_backend.sh"
fi

cd "$ROOT_DIR"
PYTHONPATH="$ROOT_DIR/backend" .venv/bin/python -m pytest tests -q
