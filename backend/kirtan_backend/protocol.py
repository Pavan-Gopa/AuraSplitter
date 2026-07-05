from __future__ import annotations

import json
import platform
from dataclasses import dataclass
from typing import Any

from .jobs import SeparationJob
from .presets import PRESETS, preset_list, resolve_model_filename


@dataclass(frozen=True)
class BackendRequest:
    id: str
    method: str
    params: dict[str, Any]

    @classmethod
    def from_json(cls, raw: str) -> "BackendRequest":
        data = json.loads(raw)
        return cls(
            id=str(data.get("id", "")),
            method=str(data.get("method", "")),
            params=dict(data.get("params") or {}),
        )

    def to_json(self) -> str:
        return json.dumps(
            {"id": self.id, "method": self.method, "params": self.params},
            ensure_ascii=False,
        )


def response(request_id: str, result: dict) -> dict:
    return {"type": "response", "id": request_id, "result": result}


def error_response(request_id: str, message: str) -> dict:
    return {"type": "error", "id": request_id, "error": message}


def progress_event(request_id: str, stage: str, message: str, progress: float, runtime: dict | None = None) -> dict:
    clamped = min(1.0, max(0.0, float(progress)))
    event = {
        "type": "progress",
        "id": request_id,
        "stage": stage,
        "message": message,
        "progress": round(clamped, 3),
    }
    if runtime is not None:
        event["runtime"] = runtime
    return event


def handle_request(request: BackendRequest, engine, emit_event=None) -> tuple[dict, list[dict]]:
    events: list[dict] = []

    def collect_event(event: dict):
        events.append(event)
        if emit_event is not None:
            emit_event(event)

    try:
        if request.method == "ping":
            result = {
                "status": "ok",
                "backend": "mlx-audio-separator",
                "gpu": "MLX/Metal",
                "python": platform.python_version(),
            }
            if hasattr(engine, "health"):
                try:
                    result.update(engine.health())
                except Exception as exc:
                    result["healthWarning"] = str(exc)
            return response(request.id, result), events

        if request.method == "list_presets":
            return response(request.id, {"presets": preset_list()}), events

        if request.method == "list_models":
            limit = int(request.params.get("limit", 500))
            return response(request.id, {"models": engine.list_models(limit=limit)}), events

        if request.method == "runtime_stats":
            return response(request.id, engine.runtime_stats()), events

        if request.method == "model_cache":
            return response(request.id, engine.model_cache()), events

        if request.method == "delete_model_cache_item":
            item_path = request.params.get("path") or request.params.get("filename")
            if not item_path:
                raise ValueError("Missing required parameter: path")
            return response(request.id, engine.delete_model_cache_item(str(item_path))), events

        if request.method == "delete_model_group_source":
            group_id = request.params.get("groupID") or request.params.get("groupId") or request.params.get("id")
            if not group_id:
                raise ValueError("Missing required parameter: groupID")
            return response(request.id, engine.delete_model_group_source(str(group_id))), events

        if request.method == "separate":
            preset_id = str(request.params.get("preset", "kirtan_pro"))
            explicit_model = request.params.get("modelFilename")
            if preset_id not in PRESETS and not explicit_model:
                raise ValueError(f"Unknown preset: {preset_id}")

            model_filename = resolve_model_filename(preset_id, explicit_model)
            job = SeparationJob.from_params(request.params, model_filename=model_filename)

            def emit(stage: str, message: str, progress: float, runtime: dict | None = None):
                collect_event(progress_event(request.id, stage, message, progress, runtime=runtime))

            result = engine.separate(job, emit)
            return response(request.id, result), events

        if request.method == "cancel":
            return response(request.id, {"cancelled": False, "reason": "Current MLX job cannot be interrupted safely yet."}), events

        return error_response(request.id, f"Unknown method: {request.method}"), events

    except Exception as exc:
        return error_response(request.id, f"{type(exc).__name__}: {exc}"), events
