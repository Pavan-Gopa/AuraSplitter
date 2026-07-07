import json
import subprocess
import sys
import types
import wave
from pathlib import Path

import pytest

import kirtan_backend.engine as engine_module
from kirtan_backend.engine import MlxSeparatorEngine
from kirtan_backend.jobs import SeparationJob
from kirtan_backend.protocol import BackendRequest, handle_request
from kirtan_backend.presets import PRESETS


class FakeEngine:
    def __init__(self):
        self.calls = []
        self.last_model_limit = None
        self.cancel_reason = None

    def list_models(self, limit=80):
        self.last_model_limit = limit
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

    def runtime_stats(self):
        return {
            "cpu": {"systemPercent": 12.5, "coreCount": 10},
            "memory": {"totalBytes": 1000, "usedBytes": 550, "usedPercent": 55.0},
            "process": {"pid": 123, "cpuPercent": 22.0, "rssBytes": 200},
            "gpu": {"device": "Device(gpu, 0)", "utilizationPercent": None, "status": "unavailable"},
        }

    def model_cache(self):
        return {
            "modelDir": "/tmp/models",
            "totalBytes": 42,
            "items": [
                {
                    "filename": "BS-Roformer-SW.ckpt",
                    "sizeBytes": 20,
                    "kind": "checkpoint",
                    "converted": True,
                },
                {
                    "filename": "BS-Roformer-SW.safetensors",
                    "sizeBytes": 22,
                    "kind": "converted",
                    "converted": True,
                },
            ],
        }

    def delete_model_cache_item(self, item_path):
        assert item_path == "/tmp/models/BS-Roformer-SW.safetensors"
        return {
            "modelDir": "/tmp/models",
            "totalBytes": 20,
            "items": [
                {
                    "filename": "BS-Roformer-SW.ckpt",
                    "sizeBytes": 20,
                    "kind": "checkpoint",
                    "converted": False,
                }
            ],
            "deleted": {
                "filename": "BS-Roformer-SW.safetensors",
                "path": item_path,
                "sizeBytes": 22,
            },
        }

    def delete_model_group_source(self, group_id):
        assert group_id == "BS-Roformer-SW"
        return {
            "modelDir": "/tmp/models",
            "totalBytes": 22,
            "items": [],
            "groups": [
                {
                    "id": "BS-Roformer-SW",
                    "displayName": "BS-Roformer-SW",
                    "converted": True,
                    "hasSource": False,
                    "sourceRemoved": True,
                    "canDeleteSource": False,
                    "totalBytes": 22,
                    "sourceBytes": 0,
                    "convertedBytes": 22,
                    "configBytes": 5,
                    "files": [],
                }
            ],
            "deleted": {
                "filename": "BS-Roformer-SW.ckpt",
                "replacedWithPlaceholder": True,
            },
        }

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

    def cancel_current(self, reason):
        self.cancel_reason = reason
        return {
            "cancelled": True,
            "reason": reason,
            "backendRestartRequired": True,
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


def test_heartbeat_progress_does_not_pin_near_stage_end_after_two_minutes():
    assert hasattr(engine_module, "_heartbeat_progress_value")

    value = engine_module._heartbeat_progress_value(start=0.35, end=0.92, elapsed_seconds=120)

    assert 0.35 < value < 0.78


def test_progress_message_reports_elapsed_time_for_long_running_stages():
    assert hasattr(engine_module, "_progress_message")

    message = engine_module._progress_message("Running MLX separation", elapsed_seconds=125)

    assert message == "Running MLX separation - elapsed 2m 5s"


def test_list_presets_exposes_kirtan_focused_defaults():
    response, _ = handle_request(
        BackendRequest(id="r2", method="list_presets", params={}),
        engine=FakeEngine(),
    )

    presets = response["result"]["presets"]
    preset_ids = {preset["id"] for preset in presets}
    assert {"kirtan_pro", "vocal_clean", "instrument_bleed", "viperx_vocal", "viperx_karaoke"}.issubset(preset_ids)
    assert PRESETS["kirtan_pro"].model_filename == "BS-Roformer-SW.ckpt"
    assert PRESETS["viperx_vocal"].model_filename == "model_bs_roformer_ep_368_sdr_12.9628.ckpt"
    assert PRESETS["viperx_karaoke"].model_filename == "mel_band_roformer_karaoke_aufr33_viperx_sdr_10.1956.ckpt"


def test_list_models_defaults_to_full_catalog_limit():
    engine = FakeEngine()

    response, events = handle_request(
        BackendRequest(id="r-models", method="list_models", params={}),
        engine=engine,
    )

    assert events == []
    assert response["type"] == "response"
    assert engine.last_model_limit == 500


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
            "mdxcSegmentSize": 384,
            "mdxcOverlap": 10,
            "mdxcBatchSize": 2,
            "mdxcOverrideModelSegmentSize": True,
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
    assert engine.calls[0].mdxc_segment_size == 384
    assert engine.calls[0].mdxc_overlap == 10
    assert engine.calls[0].mdxc_batch_size == 2
    assert engine.calls[0].mdxc_override_model_segment_size is True


def test_separate_accepts_snake_case_mdxc_parameters(tmp_path):
    engine = FakeEngine()
    request = BackendRequest(
        id="r3-mdxc-snake",
        method="separate",
        params={
            "inputPath": "/tmp/mix.wav",
            "outputDir": str(tmp_path),
            "preset": "kirtan_pro",
            "mdxc_segment_size": 128,
            "mdxc_overlap": 4,
            "mdxc_batch_size": 1,
            "mdxc_override_model_segment_size": False,
        },
    )

    response, _events = handle_request(request, engine=engine)

    assert response["type"] == "response"
    assert engine.calls[0].mdxc_segment_size == 128
    assert engine.calls[0].mdxc_overlap == 4
    assert engine.calls[0].mdxc_batch_size == 1
    assert engine.calls[0].mdxc_override_model_segment_size is False


def test_separate_streams_progress_when_emit_callback_is_provided(tmp_path):
    streamed = []
    response, events = handle_request(
        BackendRequest(
            id="r3-stream",
            method="separate",
            params={
                "inputPath": "/tmp/mix.wav",
                "outputDir": str(tmp_path),
                "preset": "kirtan_pro",
            },
        ),
        engine=FakeEngine(),
        emit_event=streamed.append,
    )

    assert response["type"] == "response"
    assert events == streamed
    assert streamed[0]["type"] == "progress"
    assert streamed[0]["stage"] == "loading"


def test_cancel_requests_current_backend_job_restart():
    engine = FakeEngine()

    response, events = handle_request(
        BackendRequest(
            id="r-cancel",
            method="cancel",
            params={"reason": "User cancelled batch"},
        ),
        engine=engine,
    )

    assert events == []
    assert response["type"] == "response"
    assert response["id"] == "r-cancel"
    assert response["result"]["cancelled"] is True
    assert response["result"]["backendRestartRequired"] is True
    assert engine.cancel_reason == "User cancelled batch"


def test_runtime_stats_returns_process_memory_cpu_and_gpu_status():
    response, events = handle_request(
        BackendRequest(id="r-stats", method="runtime_stats", params={}),
        engine=FakeEngine(),
    )

    assert events == []
    assert response["type"] == "response"
    assert response["result"]["process"]["pid"] == 123
    assert response["result"]["memory"]["usedPercent"] == 55.0
    assert response["result"]["gpu"]["device"] == "Device(gpu, 0)"


def test_model_cache_reports_checkpoints_and_converted_weights():
    response, events = handle_request(
        BackendRequest(id="r-cache", method="model_cache", params={}),
        engine=FakeEngine(),
    )

    assert events == []
    assert response["type"] == "response"
    assert response["result"]["totalBytes"] == 42
    assert response["result"]["items"][0]["converted"] is True


def test_delete_model_cache_item_returns_refreshed_cache():
    response, events = handle_request(
        BackendRequest(
            id="r-cache-delete",
            method="delete_model_cache_item",
            params={"path": "/tmp/models/BS-Roformer-SW.safetensors"},
        ),
        engine=FakeEngine(),
    )

    assert events == []
    assert response["type"] == "response"
    assert response["result"]["deleted"]["filename"] == "BS-Roformer-SW.safetensors"
    assert response["result"]["totalBytes"] == 20
    assert [item["filename"] for item in response["result"]["items"]] == ["BS-Roformer-SW.ckpt"]


def test_delete_model_group_source_returns_refreshed_group_cache():
    response, events = handle_request(
        BackendRequest(
            id="r-group-delete-source",
            method="delete_model_group_source",
            params={"groupID": "BS-Roformer-SW"},
        ),
        engine=FakeEngine(),
    )

    assert events == []
    assert response["type"] == "response"
    assert response["result"]["deleted"]["filename"] == "BS-Roformer-SW.ckpt"
    assert response["result"]["deleted"]["replacedWithPlaceholder"] is True
    assert response["result"]["groups"][0]["sourceRemoved"] is True


def test_analyze_audio_returns_preview_data(tmp_path):
    input_path = tmp_path / "mono.wav"
    _write_silent_wav(input_path, channels=1)

    response, events = handle_request(
        BackendRequest(
            id="r-analyze",
            method="analyze_audio",
            params={"path": str(input_path), "waveformPoints": 64, "spectrogramColumns": 24, "spectrogramBins": 16},
        ),
        engine=MlxSeparatorEngine(model_dir=str(tmp_path / "models")),
    )

    assert events == []
    assert response["type"] == "response"
    result = response["result"]
    assert result["channels"] == 1
    assert result["durationSeconds"] > 0
    assert result["peakDb"] <= 0
    assert result["clipped"] is False
    assert len(result["waveformPeaks"]) == 64
    assert result["spectrogram"]["columns"] == 24
    assert result["spectrogram"]["bins"] == 16
    assert len(result["spectrogram"]["values"]) == 24 * 16


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


def test_engine_converts_mono_input_before_running_separator(tmp_path, monkeypatch):
    input_path = tmp_path / "mono.wav"
    _write_silent_wav(input_path, channels=1)
    model_dir = tmp_path / "models"
    output_dir = tmp_path / "out"

    class FakeSeparator:
        last_audio_path = None

        def __init__(self, *args, output_dir, **kwargs):
            self.output_dir = Path(output_dir)
            self.last_perf_metrics = {}

        def load_model(self, model_filename):
            return None

        def separate(self, audio_path):
            FakeSeparator.last_audio_path = Path(audio_path)
            assert _audio_channels(FakeSeparator.last_audio_path) == 2
            output = self.output_dir / "mono_(vocals).wav"
            _write_silent_wav(output, channels=2)
            return [str(output)]

    _install_fake_separator(monkeypatch, FakeSeparator)
    engine = MlxSeparatorEngine(model_dir=str(model_dir))
    monkeypatch.setattr(engine, "runtime_stats", lambda: {})
    monkeypatch.setattr(engine, "model_cache", lambda: {"items": [], "totalBytes": 0, "modelDir": str(model_dir)})

    result = engine.separate(
        SeparationJob(
            input_path=str(input_path),
            output_dir=str(output_dir),
            model_filename="BS-Roformer-SW.ckpt",
            preset="kirtan_pro",
        ),
        progress=lambda *_args: None,
    )

    assert result["files"][0]["stem"] == "vocals"
    assert FakeSeparator.last_audio_path != input_path


def test_engine_restores_mono_outputs_for_mono_sources(tmp_path, monkeypatch):
    input_path = tmp_path / "mono.wav"
    _write_silent_wav(input_path, channels=1)
    model_dir = tmp_path / "models"
    output_dir = tmp_path / "out"

    class StereoOutputSeparator:
        last_audio_path = None

        def __init__(self, *args, output_dir, **kwargs):
            self.output_dir = Path(output_dir)
            self.last_perf_metrics = {}

        def load_model(self, model_filename):
            return None

        def separate(self, audio_path):
            StereoOutputSeparator.last_audio_path = Path(audio_path)
            assert _audio_channels(StereoOutputSeparator.last_audio_path) == 2
            output = self.output_dir / "mono_(vocals).wav"
            _write_silent_wav(output, channels=2)
            return [str(output)]

    _install_fake_separator(monkeypatch, StereoOutputSeparator)
    engine = MlxSeparatorEngine(model_dir=str(model_dir))
    monkeypatch.setattr(engine, "runtime_stats", lambda: {})
    monkeypatch.setattr(engine, "model_cache", lambda: {"items": [], "totalBytes": 0, "modelDir": str(model_dir)})

    result = engine.separate(
        SeparationJob(
            input_path=str(input_path),
            output_dir=str(output_dir),
            model_filename="BS-Roformer-SW.ckpt",
            preset="kirtan_pro",
            output_format="WAV",
        ),
        progress=lambda *_args: None,
    )

    assert _audio_channels(Path(result["files"][0]["path"])) == 1


def test_engine_keeps_stereo_outputs_for_stereo_sources(tmp_path, monkeypatch):
    input_path = tmp_path / "stereo.wav"
    _write_silent_wav(input_path, channels=2)
    model_dir = tmp_path / "models"
    output_dir = tmp_path / "out"

    class StereoOutputSeparator:
        last_audio_path = None

        def __init__(self, *args, output_dir, **kwargs):
            self.output_dir = Path(output_dir)
            self.last_perf_metrics = {}

        def load_model(self, model_filename):
            return None

        def separate(self, audio_path):
            StereoOutputSeparator.last_audio_path = Path(audio_path)
            assert StereoOutputSeparator.last_audio_path == input_path
            output = self.output_dir / "stereo_(vocals).wav"
            _write_silent_wav(output, channels=2)
            return [str(output)]

    _install_fake_separator(monkeypatch, StereoOutputSeparator)
    engine = MlxSeparatorEngine(model_dir=str(model_dir))
    monkeypatch.setattr(engine, "runtime_stats", lambda: {})
    monkeypatch.setattr(engine, "model_cache", lambda: {"items": [], "totalBytes": 0, "modelDir": str(model_dir)})

    result = engine.separate(
        SeparationJob(
            input_path=str(input_path),
            output_dir=str(output_dir),
            model_filename="BS-Roformer-SW.ckpt",
            preset="kirtan_pro",
            output_format="WAV",
        ),
        progress=lambda *_args: None,
    )

    assert _audio_channels(Path(result["files"][0]["path"])) == 2


def test_engine_rejects_separator_runs_that_return_no_files(tmp_path, monkeypatch):
    input_path = tmp_path / "stereo.wav"
    _write_silent_wav(input_path, channels=2)
    model_dir = tmp_path / "models"

    class EmptySeparator:
        last_perf_metrics = {}

        def __init__(self, *args, **kwargs):
            pass

        def load_model(self, model_filename):
            return None

        def separate(self, audio_path):
            return []

    _install_fake_separator(monkeypatch, EmptySeparator)
    engine = MlxSeparatorEngine(model_dir=str(model_dir))
    monkeypatch.setattr(engine, "runtime_stats", lambda: {})
    monkeypatch.setattr(engine, "model_cache", lambda: {"items": [], "totalBytes": 0, "modelDir": str(model_dir)})

    with pytest.raises(RuntimeError, match="No output stems"):
        engine.separate(
            SeparationJob(
                input_path=str(input_path),
                output_dir=str(tmp_path / "out"),
                model_filename="BS-Roformer-SW.ckpt",
                preset="kirtan_pro",
            ),
            progress=lambda *_args: None,
        )


def test_engine_list_models_applies_uvr_favorite_aliases(tmp_path, monkeypatch):
    class FakeSeparator:
        def __init__(self, *args, **kwargs):
            pass

        def get_simplified_model_list(self, filter_sort_by=None):
            return {
                "model_bs_roformer_ep_368_sdr_12.9628.ckpt": {
                    "Name": "Roformer Model: BS-Roformer-Viperx-1296",
                    "Type": "MDXC",
                    "Stems": ["vocals* (12.1)", "instrumental (16.3)"],
                    "SDR": {"vocals": 12.1, "instrumental": 16.3},
                },
                "mel_band_roformer_karaoke_aufr33_viperx_sdr_10.1956.ckpt": {
                    "Name": "Roformer Model: Mel-Roformer-Karaoke-Aufr33-Viperx",
                    "Type": "MDXC",
                    "Stems": ["vocals* (8.4)", "instrumental (14.7)"],
                    "SDR": {"vocals": 8.4, "instrumental": 14.7},
                },
            }

    _install_fake_separator(monkeypatch, FakeSeparator)
    engine = MlxSeparatorEngine(model_dir=str(tmp_path / "models"))

    models = engine.list_models(limit=20)

    names = {model["filename"]: model["name"] for model in models}
    assert names["model_bs_roformer_ep_368_sdr_12.9628.ckpt"] == "BS-Roformer-Viperx-1296"
    assert names["mel_band_roformer_karaoke_aufr33_viperx_sdr_10.1956.ckpt"] == "MB-Ro-Kara-AuFR33-Viperx"


def test_engine_reports_model_load_state_for_converted_and_first_run_models(tmp_path):
    engine = MlxSeparatorEngine(model_dir=str(tmp_path / "models"))
    model_dir = Path(engine.model_dir)
    model_dir.mkdir(parents=True, exist_ok=True)

    assert engine._model_load_message("BS-Roformer-SW.ckpt") == "Downloading and converting model for MLX on first run"

    (model_dir / "BS-Roformer-SW.ckpt").write_bytes(b"checkpoint")
    assert engine._model_load_message("BS-Roformer-SW.ckpt") == "Converting model for MLX on first run"

    (model_dir / "BS-Roformer-SW.safetensors").write_bytes(b"converted")
    assert engine._model_load_message("BS-Roformer-SW.ckpt") == "Using converted MLX model"


def _install_fake_separator(monkeypatch, separator_class):
    monkeypatch.setitem(
        sys.modules,
        "mlx_audio_separator",
        types.SimpleNamespace(Separator=separator_class),
    )


def _write_silent_wav(path: Path, channels: int):
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(channels)
        wav.setsampwidth(2)
        wav.setframerate(44100)
        wav.writeframes(b"\0\0" * channels * 4410)


def _audio_channels(path: Path) -> int:
    output = subprocess.check_output(
        [
            "ffprobe",
            "-v",
            "error",
            "-select_streams",
            "a:0",
            "-show_entries",
            "stream=channels",
            "-of",
            "default=noprint_wrappers=1:nokey=1",
            str(path),
        ],
        text=True,
    )
    return int(output.strip())
