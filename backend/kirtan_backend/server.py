from __future__ import annotations

import argparse
import json
import logging
import os
import sys
import threading
from pathlib import Path

from .engine import MlxSeparatorEngine
from .protocol import BackendRequest, error_response, handle_request


_send_lock = threading.Lock()


def send(message: dict):
    with _send_lock:
        sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")
        sys.stdout.flush()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="KirtanSplitter MLX backend")
    parser.add_argument(
        "--model-dir",
        default=os.environ.get("KIRTAN_SPLITTER_MODEL_DIR", str(project_root() / "models")),
        help="Directory for downloaded and converted model files.",
    )
    parser.add_argument("--debug", action="store_true", help="Enable backend debug logging.")
    return parser


def project_root() -> Path:
    return Path(__file__).resolve().parents[2]


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    logging.basicConfig(
        stream=sys.stderr,
        level=logging.DEBUG if args.debug else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    logger = logging.getLogger("kirtan_backend")

    engine = MlxSeparatorEngine(model_dir=args.model_dir, logger=logger)
    send({"type": "ready", "backend": "mlx-audio-separator", "modelDir": str(args.model_dir)})

    for raw in sys.stdin:
        raw = raw.strip()
        if not raw:
            continue
        try:
            request = BackendRequest.from_json(raw)
            result, _events = handle_request(request, engine=engine, emit_event=send)
            send(result)
        except json.JSONDecodeError as exc:
            send(error_response("", f"JSONDecodeError: {exc}"))
        except Exception as exc:
            logger.exception("Unhandled backend error")
            send(error_response("", f"{type(exc).__name__}: {exc}"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
