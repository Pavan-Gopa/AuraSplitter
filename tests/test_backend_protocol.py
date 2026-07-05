import json
from pathlib import Path

import pytest

from kirtan_backend.protocol import BackendRequest, handle_request
from kirtan_backend.presets import PRESETS


class FakeEngine:
    def __init__(self):
        self.calls = []

    def list_models(self, limit=80):
        return [
            {
                "filename": "BS-Roformer-SW.ckpt",
                "name": "Roformer Model: BS Roformer SW by jarredou",
                "type": "MDXC",
                "stems": ["vocals", "drums", "bass", "guitar", "piano", "other"],
                "sdr": {},
                "isDownloaded": False,
            }
        ]

    def separate(self, job, progress):
        self.calls.append(job)
        progress("loading", "Loading model", 0.1)
        progress("separating", "Separating audio", 0.7)
        return {
            "files": [
                {
                    "stem": "vocals",
                    "path": str(Path(job.output_dir) / "mix_(Vocals).flac"),
                    "sizeBytes": 42,
                }
            ],
            "elapsedSeconds": 1.25,
            "model": job.model_filename,
        }


def test_ping_returns_backend_capabilities():
    response, events = handle_request(
        BackendRequest(id="r1", method="ping", params={}),
        engine=FakeEngine(),
    )

    assert events == []
    assert response["type"] == "response"
    assert response["id"] == "r1"
    assert response["result"]["status"] == "ok"
    assert response["result"]["backend"] == "mlx-audio-separator"
    assert response["result"]["gpu"] == "MLX/Metal"


def test_list_presets_exposes_kirtan_focused_defaults():
    response, _ = handle_request(
        BackendRequest(id="r2", method="list_presets", params={}),
        engine=FakeEngine(),
    )

    presets = response["result"]["presets"]
    preset_ids = {preset["id"] for preset in presets}
    assert {"kirtan_pro", "vocal_clean", "instrument_bleed"}.issubset(preset_ids)
    assert PRESETS["kirtan_pro"].model_filename == "BS-Roformer-SW.ckpt"


def test_separate_uses_preset_model_and_emits_progress_events(tmp_path):
    engine = FakeEngine()
    request = BackendRequest(
        id="r3",
        method="separate",
        params={
            "inputPath": "/tmp/mix.wav",
            "outputDir": str(tmp_path),
            "preset": "kirtan_pro",
            "outputFormat": "FLAC",
            "chunkDuration": 30,
            "speedMode": "latency_safe_v3",
        },
    )

    response, events = handle_request(request, engine=engine)

    assert [event["type"] for event in events] == ["progress", "progress"]
    assert events[0]["stage"] == "loading"
    assert response["type"] == "response"
    assert response["result"]["model"] == "BS-Roformer-SW.ckpt"
    assert response["result"]["files"][0]["stem"] == "vocals"
    assert engine.calls[0].input_path == "/tmp/mix.wav"
    assert engine.calls[0].output_format == "FLAC"
    assert engine.calls[0].speed_mode == "latency_safe_v3"


def test_separate_rejects_missing_input_path(tmp_path):
    response, events = handle_request(
        BackendRequest(
            id="r4",
            method="separate",
            params={"outputDir": str(tmp_path), "preset": "kirtan_pro"},
        ),
        engine=FakeEngine(),
    )

    assert events == []
    assert response["type"] == "error"
    assert response["id"] == "r4"
    assert "inputPath" in response["error"]


def test_backend_request_round_trips_json():
    raw = '{"id":"abc","method":"ping","params":{}}'
    request = BackendRequest.from_json(raw)

    assert request == BackendRequest(id="abc", method="ping", params={})
    assert json.loads(request.to_json()) == {
        "id": "abc",
        "method": "ping",
        "params": {},
    }


def test_unknown_method_returns_error():
    response, events = handle_request(
        BackendRequest(id="r5", method="not_real", params={}),
        engine=FakeEngine(),
    )

    assert events == []
    assert response["type"] == "error"
    assert "Unknown method" in response["error"]


@pytest.mark.parametrize("preset_id", ["kirtan_pro", "vocal_clean", "instrument_bleed"])
def test_presets_have_user_visible_labels(preset_id):
    preset = PRESETS[preset_id]

    assert preset.title
    assert preset.model_filename.endswith((".ckpt", ".onnx", ".pth", ".yaml"))
    assert preset.summary
