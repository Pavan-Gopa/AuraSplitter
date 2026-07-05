"""
JSON-RPC сервер над stdin/stdout.
Swift запускает этот процесс и общается через JSON сообщения.
Каждое сообщение — одна строка JSON, ответ — одна строка JSON.
"""

import sys
import json
import threading
from pathlib import Path

# Добавляем текущую директорию в путь
sys.path.insert(0, str(Path(__file__).parent))

from pipeline import KirtanPipeline, KIRTAN_PIPELINE, QUICK_PIPELINE, FULL_PIPELINE, PipelineStage


def send(obj: dict):
    """Отправляем JSON ответ в stdout."""
    line = json.dumps(obj, ensure_ascii=False)
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def send_progress(stage: str, progress: float, request_id: str):
    send({
        "type": "progress",
        "id": request_id,
        "stage": stage,
        "progress": round(progress, 3),
    })


def handle_request(req: dict, pipeline: KirtanPipeline):
    req_id = req.get("id", "0")
    method = req.get("method", "")
    params = req.get("params", {})

    try:
        if method == "ping":
            send({"type": "response", "id": req_id, "result": {"status": "ok", "backend": "mlx"}})

        elif method == "list_models":
            models = pipeline.get_available_models()
            send({"type": "response", "id": req_id, "result": {"models": models}})

        elif method == "separate":
            input_path = params["input_path"]
            output_dir = params["output_dir"]
            preset = params.get("preset", "kirtan")

            presets = {
                "kirtan": KIRTAN_PIPELINE,
                "quick": QUICK_PIPELINE,
                "full": FULL_PIPELINE,
            }
            stages = presets.get(preset, KIRTAN_PIPELINE)

            # Можно кастомизировать какие ступени включены
            if "enabled_stages" in params:
                for i, stage in enumerate(stages):
                    stage.enabled = i in params["enabled_stages"]

            def progress_cb(stage_name: str, progress: float):
                send_progress(stage_name, progress, req_id)

            result = pipeline.run(
                input_path=input_path,
                output_dir=output_dir,
                stages=stages,
                progress_cb=progress_cb,
            )

            if result.success:
                send({
                    "type": "response",
                    "id": req_id,
                    "result": {
                        "stems": result.stems,
                        "total_time": round(result.total_time, 2),
                    }
                })
            else:
                send({
                    "type": "error",
                    "id": req_id,
                    "error": result.error,
                })

        elif method == "cancel":
            # TODO: реализовать отмену через threading.Event
            send({"type": "response", "id": req_id, "result": {"cancelled": True}})

        else:
            send({"type": "error", "id": req_id, "error": f"Неизвестный метод: {method}"})

    except Exception as e:
        import traceback
        send({
            "type": "error",
            "id": req_id,
            "error": f"{type(e).__name__}: {e}",
            "traceback": traceback.format_exc(),
        })


def main():
    send({"type": "ready", "backend": "mlx", "version": "1.0.0"})

    pipeline = KirtanPipeline(
        models_dir=str(Path(__file__).parent.parent / "models"),
        chunk_seconds=30.0,
    )

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError as e:
            send({"type": "error", "error": f"Невалидный JSON: {e}"})
            continue

        # Обрабатываем в отдельном потоке чтобы не блокировать stdin
        t = threading.Thread(target=handle_request, args=(req, pipeline), daemon=True)
        t.start()
        t.join()  # Пока обрабатываем последовательно; можно распараллелить


if __name__ == "__main__":
    main()
