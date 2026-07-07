from __future__ import annotations

import argparse
import json
import logging
import os
import socketserver
import sys
import threading
import time
from pathlib import Path

from .engine import MlxSeparatorEngine
from .protocol import BackendRequest, error_response, handle_request


_send_lock = threading.Lock()
_stream_logger = logging.getLogger("kirtan_backend.stream")


def log_stream_message(message: dict):
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


def send(message: dict):
    with _send_lock:
        sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")
        sys.stdout.flush()
    log_stream_message(message)


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
    parser.add_argument("--tcp-host", default=None, help="Serve JSON-lines protocol on this host instead of stdio.")
    parser.add_argument("--tcp-port", type=int, default=None, help="Serve JSON-lines protocol on this TCP port.")
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


def ready_payload(args, log_path: Path) -> dict:
    payload = {
        "type": "ready",
        "backend": "mlx-audio-separator",
        "modelDir": str(args.model_dir),
        "logFile": str(log_path),
    }
    if args.tcp_host and args.tcp_port:
        payload["tcpHost"] = args.tcp_host
        payload["tcpPort"] = args.tcp_port
    return payload


def should_restart_after_cancel(request: BackendRequest, result: dict) -> bool:
    if request.method != "cancel":
        return False
    if result.get("type") != "response":
        return False
    response_result = result.get("result") or {}
    return bool(response_result.get("backendRestartRequired"))


def schedule_backend_restart_after_cancel(request: BackendRequest, result: dict, logger: logging.Logger):
    if not should_restart_after_cancel(request, result):
        return

    def exit_backend():
        time.sleep(0.15)
        logger.warning("Backend exiting after cancellation request so the app can start a clean worker.")
        os._exit(130)

    threading.Thread(target=exit_backend, daemon=True).start()


def run_stdio(args, engine, log_path: Path, logger: logging.Logger) -> int:
    send(ready_payload(args, log_path))
    for raw in sys.stdin:
        raw = raw.strip()
        if not raw:
            continue
        try:
            request = BackendRequest.from_json(raw)
            logger.info("request id=%s method=%s", request.id, request.method)
            result, _events = handle_request(request, engine=engine, emit_event=send)
            schedule_backend_restart_after_cancel(request, result, logger)
            send(result)
        except json.JSONDecodeError as exc:
            send(error_response("", f"JSONDecodeError: {exc}"))
        except Exception as exc:
            logger.exception("Unhandled backend error")
            send(error_response("", f"{type(exc).__name__}: {exc}"))
    return 0


class ThreadedTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True


class BackendTCPHandler(socketserver.StreamRequestHandler):
    def send_message(self, message: dict):
        self.wfile.write(json.dumps(message, ensure_ascii=False).encode("utf-8") + b"\n")
        self.wfile.flush()
        log_stream_message(message)

    def handle(self):
        logger = logging.getLogger("kirtan_backend")
        self.send_message(self.server.ready_message)
        try:
            for raw in self.rfile:
                raw_text = raw.decode("utf-8").strip()
                if not raw_text:
                    continue
                try:
                    request = BackendRequest.from_json(raw_text)
                    logger.info("request id=%s method=%s", request.id, request.method)
                    result, _events = handle_request(request, engine=self.server.engine, emit_event=self.send_message)
                    schedule_backend_restart_after_cancel(request, result, logger)
                    self.send_message(result)
                except json.JSONDecodeError as exc:
                    self.send_message(error_response("", f"JSONDecodeError: {exc}"))
                except BrokenPipeError:
                    logger.debug("TCP client disconnected before backend response was written")
                    break
                except Exception as exc:
                    logger.exception("Unhandled backend error")
                    self.send_message(error_response("", f"{type(exc).__name__}: {exc}"))
        except ConnectionResetError:
            logger.debug("TCP client disconnected during read")


def run_tcp(args, engine, log_path: Path, logger: logging.Logger) -> int:
    host = args.tcp_host or "127.0.0.1"
    with ThreadedTCPServer((host, args.tcp_port), BackendTCPHandler) as server:
        server.engine = engine
        server.ready_message = ready_payload(args, log_path)
        logger.info("TCP backend listening host=%s port=%s", host, args.tcp_port)
        server.serve_forever()
    return 0


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    log_path = configure_logging(args.log_file, args.debug)
    logger = logging.getLogger("kirtan_backend")
    logger.info("Starting backend model_dir=%s log_file=%s", args.model_dir, log_path)

    engine = MlxSeparatorEngine(model_dir=args.model_dir, logger=logger)
    if args.tcp_port is not None:
        return run_tcp(args, engine, log_path, logger)
    return run_stdio(args, engine, log_path, logger)


if __name__ == "__main__":
    raise SystemExit(main())
