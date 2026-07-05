#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${KIRTAN_SPLITTER_PYTHON:-}" ]]; then
  echo "KIRTAN_SPLITTER_PYTHON is not set" >&2
  exit 2
fi

if [[ -z "${KIRTAN_SPLITTER_BACKEND_SERVER:-}" ]]; then
  echo "KIRTAN_SPLITTER_BACKEND_SERVER is not set" >&2
  exit 2
fi

if [[ -z "${KIRTAN_SPLITTER_MODEL_DIR:-}" ]]; then
  echo "KIRTAN_SPLITTER_MODEL_DIR is not set" >&2
  exit 2
fi

if [[ -z "${KIRTAN_SPLITTER_LOG_FILE:-}" ]]; then
  echo "KIRTAN_SPLITTER_LOG_FILE is not set" >&2
  exit 2
fi

exec "$KIRTAN_SPLITTER_PYTHON" \
  "$KIRTAN_SPLITTER_BACKEND_SERVER" \
  --model-dir "$KIRTAN_SPLITTER_MODEL_DIR" \
  --log-file "$KIRTAN_SPLITTER_LOG_FILE"
