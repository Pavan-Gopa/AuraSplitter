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
_stream_logger = logging.getLogger("kirtan_backend.stream")


def send(message: dict):
    with _send_lock:
        sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")
        sys.stdout.flush()
    message_type = message.get("type", "unknown")
    if message_type == "progress":
        _stream_logger.info(
            "progress id=%s stage=%s progress=%s message=%s",
            message.get("id", ""),
            message.get("stage", ""),
            message.get("progress", ""),
            message.get("message", ""),
        )
    elif message_type in {"ready", "error"}:
        _stream_logger.info("%s %s", message_type, message)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="KirtanSplitter MLX backend")
    parser.add_argument(
        "--model-dir",
        default=os.environ.get("KIRTAN_SPLITTER_MODEL_DIR", str(project_root() / "models")),
        help="Directory for downloaded and converted model files.",
    )
    parser.add_argument(
        "--log-file",
        default=os.environ.get("KIRTAN_SPLITTER_LOG_FILE", str(project_root() / "logs" / "backend.log")),
        help="Path for persistent backend logs.",
    )
    parser.add_argument("--debug", action="store_true", help="Enable backend debug logging.")
    return parser


def project_root() -> Path:
    return Path(__file__).resolve().parents[2]


def configure_logging(log_file: str, debug: bool) -> Path:
    log_path = Path(log_file).expanduser()
    log_path.parent.mkdir(parents=True, exist_ok=True)
    formatter = logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s")
    stream_handler = logging.StreamHandler(sys.stderr)
    stream_handler.setFormatter(formatter)
    file_handler = logging.FileHandler(log_path, encoding="utf-8")
    file_handler.setFormatter(formatter)
    logging.basicConfig(
        handlers=[stream_handler, file_handler],
        level=logging.DEBUG if debug else logging.INFO,
        force=True,
    )
    return log_path


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    log_path = configure_logging(args.log_file, args.debug)
    logger = logging.getLogger("kirtan_backend")
    logger.info("Starting backend model_dir=%s log_file=%s", args.model_dir, log_path)

    engine = MlxSeparatorEngine(model_dir=args.model_dir, logger=logger)
    send({"type": "ready", "backend": "mlx-audio-separator", "modelDir": str(args.model_dir), "logFile": str(log_path)})

    for raw in sys.stdin:
        raw = raw.strip()
        if not raw:
            continue
        try:
            request = BackendRequest.from_json(raw)
            logger.info("request id=%s method=%s", request.id, request.method)
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
