import json
import subprocess
import sys
import types
import wave
from pathlib import Path

import pytest

import kirtan_backend.engine as engine_module
import kirtan_backend.model_catalog as model_catalog
from kirtan_backend import audio_analysis
from kirtan_backend.engine import MlxSeparatorEngine
from kirtan_backend.jobs import SeparationJob
from kirtan_backend.protocol import BackendRequest, handle_request
from kirtan_backend.render_estimates import record_render_benchmark
from kirtan_backend.presets import PRESETS
from kirtan_backend.server import should_restart_after_cancel


class FakeEngine:
    def __init__(self):
        self.calls = []
        self.estimate_calls = []
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

    def render_estimate(self, params, model_filename):
        self.estimate_calls.append((params, model_filename))
        return {
            "status": "calibrated",
            "estimatedSeconds": 123.0,
            "modelFilename": model_filename,
            "processPresetID": params.get("processPresetID"),
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
    assert {
        "kirtan_pro",
        "vocal_clean",
        "instrument_bleed",
        "viperx_vocal",
        "viperx_karaoke",
        "hyperace_v2_vocal",
        "leap_xe_vocal",
        "lead_back_bve_gonza",
        "drumsep_mdx23c_5stem",
        "mega_lead_vocal",
    }.issubset(preset_ids)
    assert PRESETS["kirtan_pro"].model_filename == "BS-Roformer-SW.ckpt"
    assert PRESETS["vocal_clean"].model_filename == "model_bs_roformer_ep_317_sdr_12.9755.ckpt"
    assert PRESETS["viperx_vocal"].model_filename == "model_bs_roformer_ep_368_sdr_12.9628.ckpt"
    assert PRESETS["vocal_clean"].model_filename != PRESETS["viperx_vocal"].model_filename
    assert PRESETS["viperx_karaoke"].model_filename == "mel_band_roformer_karaoke_aufr33_viperx_sdr_10.1956.ckpt"
    assert PRESETS["hyperace_v2_vocal"].model_filename == "bs_roformer_voc_hyperacev2.ckpt"


def test_list_presets_reports_local_usage_count(tmp_path):
    record_render_benchmark(
        str(tmp_path),
        {
            "modelFilename": "BS-Roformer-SW.ckpt",
            "modelPresetID": "kirtan_pro",
            "processPresetID": "builtin.fast",
            "elapsedSeconds": 300,
            "audioDurationSeconds": 300,
        },
    )
    record_render_benchmark(
        str(tmp_path),
        {
            "modelFilename": "BS-Roformer-SW.ckpt",
            "modelPresetID": "kirtan_pro",
            "processPresetID": "builtin.heavy",
            "elapsedSeconds": 600,
            "audioDurationSeconds": 300,
        },
    )
    engine = MlxSeparatorEngine(model_dir=str(tmp_path))

    response, _ = handle_request(
        BackendRequest(id="r2", method="list_presets", params={}),
        engine=engine,
    )

    presets = {preset["id"]: preset for preset in response["result"]["presets"]}
    assert presets["kirtan_pro"]["usageCount"] == 2
    assert presets["vocal_clean"]["usageCount"] == 0


def test_model_pack_presets_use_user_friendly_kirtan_titles():
    technical_tokens = {
        "HyperACE",
        "Leap",
        "Becruily",
        "BVE",
        "Anvuew",
        "MDX23C",
        "Mega 53",
        "ViperX",
        "PolarFormer",
    }

    assert PRESETS["hyperace_v2_vocal"].title == "Kirtan Vocal Pro"
    assert PRESETS["hyperace_v2_instrumental"].title == "Kirtan Instrument Pro"
    assert PRESETS["lead_back_bve_gonza"].title == "Kirtan Lead / Back"
    assert PRESETS["drumsep_mdx23c_5stem"].title == "Kirtan Drum Split"
    assert PRESETS["mega_back_vocal"].title == "Kirtan Back Vocal"

    for preset in PRESETS.values():
        for token in technical_tokens:
            assert token not in preset.title


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
            "processPresetID": "builtin.heavy",
            "processPresetTitle": "Heavy 1024",
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
    assert engine.calls[0].process_preset_id == "builtin.heavy"
    assert engine.calls[0].process_preset_title == "Heavy 1024"


def test_render_estimate_resolves_preset_model_and_forwards_params():
    engine = FakeEngine()
    request = BackendRequest(
        id="r-estimate",
        method="render_estimate",
        params={
            "preset": "kirtan_pro",
            "processPresetID": "builtin.fast",
            "durationSeconds": 2700,
            "gpuCoreCount": 10,
        },
    )

    response, events = handle_request(request, engine=engine)

    assert events == []
    assert response["type"] == "response"
    assert response["result"]["status"] == "calibrated"
    assert response["result"]["estimatedSeconds"] == 123.0
    assert response["result"]["modelFilename"] == "BS-Roformer-SW.ckpt"
    assert engine.estimate_calls[0][1] == "BS-Roformer-SW.ckpt"
    assert engine.estimate_calls[0][0]["processPresetID"] == "builtin.fast"


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


def test_separate_carries_performance_flags_into_job(tmp_path):
    engine = FakeEngine()
    request = BackendRequest(
        id="r3-flags",
        method="separate",
        params={
            "inputPath": "/tmp/mix.wav",
            "outputDir": str(tmp_path),
            "preset": "kirtan_pro",
            "performanceFlags": {
                "experimental_roformer_fast_norm": True,
                "experimental_roformer_compile_fullgraph": True,
                "experimental_flac_fast_write": True,
            },
        },
    )

    response, _events = handle_request(request, engine=engine)

    assert response["type"] == "response"
    assert engine.calls[0].performance_flags == {
        "experimental_roformer_fast_norm": True,
        "experimental_roformer_compile_fullgraph": True,
        "experimental_flac_fast_write": True,
    }


def test_separate_defaults_performance_flags_to_empty_dict(tmp_path):
    engine = FakeEngine()
    request = BackendRequest(
        id="r3-noflags",
        method="separate",
        params={
            "inputPath": "/tmp/mix.wav",
            "outputDir": str(tmp_path),
            "preset": "kirtan_pro",
        },
    )

    response, _events = handle_request(request, engine=engine)

    assert response["type"] == "response"
    assert engine.calls[0].performance_flags == {}


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


def test_cancel_restart_is_detected_before_response_write_can_fail():
    request = BackendRequest(id="r-cancel", method="cancel", params={})
    response = {
        "type": "response",
        "id": "r-cancel",
        "result": {"cancelled": True, "backendRestartRequired": True},
    }

    assert should_restart_after_cancel(request, response) is True


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
    # Happy path streams the heavy arrays through a binary ksbin payload instead
    # of inlining them in the JSON response.
    assert "waveformPeaks" not in result
    assert "spectrogram" not in result
    assert "binaryPayloadPath" in result
    payload = audio_analysis.read_analysis_ksbin(result["binaryPayloadPath"])
    assert len(payload["waveformPeaks"]) == 64
    assert payload["spectrogram"]["columns"] == 24
    assert payload["spectrogram"]["bins"] == 16
    assert len(payload["spectrogram"]["values"]) == 24 * 16


def test_analyze_audio_falls_back_to_inline_arrays_without_binary_payload(tmp_path):
    input_path = tmp_path / "mono.wav"
    _write_silent_wav(input_path, channels=1)

    response, events = handle_request(
        BackendRequest(
            id="r-analyze-inline",
            method="analyze_audio",
            params={
                "path": str(input_path),
                "waveformPoints": 32,
                "spectrogramColumns": 12,
                "spectrogramBins": 8,
                "binaryPayload": False,
            },
        ),
        engine=MlxSeparatorEngine(model_dir=str(tmp_path / "models")),
    )

    assert events == []
    result = response["result"]
    assert "binaryPayloadPath" not in result
    assert len(result["waveformPeaks"]) == 32
    assert result["spectrogram"]["columns"] == 12
    assert result["spectrogram"]["bins"] == 8
    assert len(result["spectrogram"]["values"]) == 12 * 8


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


@pytest.mark.parametrize(
    "preset_id",
    [
        "kirtan_pro",
        "vocal_clean",
        "instrument_bleed",
        "hyperace_v2_vocal",
        "lead_back_bve_gonza",
        "drumsep_mdx23c_5stem",
        "mega_lead_vocal",
    ],
)
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


def test_engine_does_not_leak_temporary_stereo_marker_into_mono_output_names(tmp_path, monkeypatch):
    input_path = tmp_path / "01MAIN_V.wav"
    _write_silent_wav(input_path, channels=1)
    model_dir = tmp_path / "models"
    output_dir = tmp_path / "out"

    class TemporaryStereoNameSeparator:
        def __init__(self, *args, output_dir, **kwargs):
            self.output_dir = Path(output_dir)
            self.last_perf_metrics = {}

        def load_model(self, model_filename):
            return None

        def separate(self, audio_path):
            assert Path(audio_path).stem == "01MAIN_V.stereo"
            output = self.output_dir / f"{Path(audio_path).stem}_(Vocals).wav"
            _write_silent_wav(output, channels=2)
            return [str(output)]

    _install_fake_separator(monkeypatch, TemporaryStereoNameSeparator)
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

    output_path = Path(result["files"][0]["path"])
    assert output_path.name == "01MAIN_V_(Vocals)_Kirtan Pro.wav"
    assert "stereo" not in output_path.name.lower()
    assert _audio_channels(output_path) == 1


def test_engine_writes_kirtan_model_metadata_to_output_files(tmp_path, monkeypatch):
    input_path = tmp_path / "mono.wav"
    _write_silent_wav(input_path, channels=1)
    model_dir = tmp_path / "models"
    output_dir = tmp_path / "out"

    class MetadataSeparator:
        def __init__(self, *args, output_dir, **kwargs):
            self.output_dir = Path(output_dir)
            self.last_perf_metrics = {}

        def load_model(self, model_filename):
            return None

        def separate(self, audio_path):
            output = self.output_dir / f"{Path(audio_path).stem}_(Vocals).wav"
            _write_silent_wav(output, channels=2)
            return [str(output)]

    _install_fake_separator(monkeypatch, MetadataSeparator)
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
            process_preset_id="builtin.heavy",
            process_preset_title="Heavy 1024",
        ),
        progress=lambda *_args: None,
    )

    tags = _audio_tags(Path(result["files"][0]["path"]))
    assert tags["encoded_by"] == "KirtanSplitter"
    assert "model=Kirtan Pro" in tags["comment"]
    assert "checkpoint=BS-Roformer-SW.ckpt" in tags["comment"]
    assert "preset=kirtan_pro" in tags["comment"]
    assert "process=Heavy 1024" in tags["comment"]


def test_engine_restores_source_format_after_mlx_separator_output(tmp_path, monkeypatch):
    input_path = tmp_path / "mono_48k.wav"
    _write_silent_wav(input_path, channels=1, sample_rate=48_000, sample_width=3)
    model_dir = tmp_path / "models"
    output_dir = tmp_path / "out"

    class Separator44100Output:
        def __init__(self, *args, output_dir, **kwargs):
            self.output_dir = Path(output_dir)
            self.last_perf_metrics = {}

        def load_model(self, model_filename):
            return None

        def separate(self, audio_path):
            output = self.output_dir / f"{Path(audio_path).stem}_(Vocals).wav"
            _write_silent_wav(output, channels=2, sample_rate=44_100)
            return [str(output)]

    _install_fake_separator(monkeypatch, Separator44100Output)
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

    output_path = Path(result["files"][0]["path"])
    assert _audio_channels(output_path) == 1
    assert _audio_sample_rate(output_path) == 48_000
    assert _audio_bit_depth(output_path) == 24
    assert _audio_codec(output_path) == "pcm_s24le"


def test_engine_keeps_stereo_outputs_for_stereo_sources(tmp_path, monkeypatch):
    input_path = tmp_path / "stereo.wav"
    _write_silent_wav(input_path, channels=2, sample_rate=48_000, sample_width=3)
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
            _write_silent_wav(output, channels=2, sample_rate=44_100, sample_width=2)
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

    output_path = Path(result["files"][0]["path"])
    assert _audio_channels(output_path) == 2
    assert _audio_sample_rate(output_path) == 48_000
    assert _audio_bit_depth(output_path) == 24
    assert _audio_codec(output_path) == "pcm_s24le"


def test_engine_preserves_source_float32_wav_codec(tmp_path, monkeypatch):
    input_path = tmp_path / "float32_48k.wav"
    _write_float_wav(input_path, channels=2, sample_rate=48_000)
    model_dir = tmp_path / "models"
    output_dir = tmp_path / "out"

    class Int16OutputSeparator:
        last_audio_path = None

        def __init__(self, *args, output_dir, **kwargs):
            self.output_dir = Path(output_dir)
            self.last_perf_metrics = {}

        def load_model(self, model_filename):
            return None

        def separate(self, audio_path):
            Int16OutputSeparator.last_audio_path = Path(audio_path)
            assert Int16OutputSeparator.last_audio_path == input_path
            output = self.output_dir / "float32_48k_(vocals).wav"
            _write_silent_wav(output, channels=2, sample_rate=44_100, sample_width=2)
            return [str(output)]

    _install_fake_separator(monkeypatch, Int16OutputSeparator)
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

    output_path = Path(result["files"][0]["path"])
    assert _audio_channels(output_path) == 2
    assert _audio_sample_rate(output_path) == 48_000
    assert _audio_bit_depth(output_path) == 32
    assert _audio_codec(output_path) == "pcm_f32le"


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
    assert names["model_bs_roformer_ep_368_sdr_12.9628.ckpt"] == "Kirtan Vocal Classic"
    assert names["mel_band_roformer_karaoke_aufr33_viperx_sdr_10.1956.ckpt"] == "Kirtan Karaoke Classic"


def test_engine_list_models_includes_kirtan_model_pack(tmp_path, monkeypatch):
    class CatalogAwareFakeSeparator:
        def __init__(self, *args, **kwargs):
            pass

        def list_supported_model_files(self):
            return {"MDXC": {}}

        def get_simplified_model_list(self, filter_sort_by=None):
            simplified = {}
            for model_type, models in self.list_supported_model_files().items():
                for name, info in models.items():
                    simplified[info["filename"]] = {
                        "Name": name,
                        "Type": model_type,
                        "Stems": info.get("stems", []),
                        "SDR": {stem: None for stem in info.get("stems", [])},
                    }
            return simplified

    _install_fake_separator(monkeypatch, CatalogAwareFakeSeparator)
    engine = MlxSeparatorEngine(model_dir=str(tmp_path / "models"))

    models = engine.list_models(limit=500)

    names = {model["filename"]: model["name"] for model in models}
    downloaded = {model["filename"]: model["isDownloaded"] for model in models}
    assert names["bs_roformer_voc_hyperacev2.ckpt"] == "Kirtan Vocal Pro"
    assert names["mel_band_roformer_bve_gonza.ckpt"] == "Kirtan Lead / Back"


def test_engine_downloads_model_pack_assets_before_loading(tmp_path, monkeypatch):
    input_path = tmp_path / "stereo.wav"
    _write_silent_wav(input_path, channels=2)
    model_dir = tmp_path / "models"
    output_dir = tmp_path / "out"
    downloaded = []

    def fake_download(url, output_path, logger):
        downloaded.append((url, output_path.name))
        output_path.write_bytes(b"asset")

    monkeypatch.setattr(model_catalog, "_download_asset", fake_download)

    class FakeSeparator:
        last_model_filename = None

        def __init__(self, *args, output_dir, **kwargs):
            self.output_dir = Path(output_dir)
            self.last_perf_metrics = {}

        def list_supported_model_files(self):
            return {"MDXC": {}}

        def load_model(self, model_filename):
            FakeSeparator.last_model_filename = model_filename
            assert (model_dir / "bs_roformer_voc_hyperacev2.ckpt").is_file()
            assert (model_dir / "bs_roformer_voc_hyperacev2.yaml").is_file()

        def separate(self, audio_path):
            output = self.output_dir / "stereo_(vocals).wav"
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
            model_filename="bs_roformer_voc_hyperacev2.ckpt",
            preset="hyperace_v2_vocal",
            output_format="WAV",
        ),
        progress=lambda *_args: None,
    )

    assert FakeSeparator.last_model_filename == "bs_roformer_voc_hyperacev2.ckpt"
    assert result["files"][0]["stem"] == "vocals"
    assert {name for _url, name in downloaded} == {
        "bs_roformer_voc_hyperacev2.ckpt",
        "bs_roformer_voc_hyperacev2.yaml",
    }

def test_engine_reports_model_load_state_for_converted_and_first_run_models(tmp_path):
    engine = MlxSeparatorEngine(model_dir=str(tmp_path / "models"))
    model_dir = Path(engine.model_dir)
    model_dir.mkdir(parents=True, exist_ok=True)

    assert engine._model_load_message("BS-Roformer-SW.ckpt") == "Downloading and converting model for MLX on first run"

    (model_dir / "BS-Roformer-SW.ckpt").write_bytes(b"checkpoint")
    assert engine._model_load_message("BS-Roformer-SW.ckpt") == "Converting model for MLX on first run"

    (model_dir / "BS-Roformer-SW.safetensors").write_bytes(b"converted")
    assert engine._model_load_message("BS-Roformer-SW.ckpt") == "Using converted MLX model"


def test_engine_reuses_cached_separator_for_same_fingerprint(tmp_path, monkeypatch):
    input_path = tmp_path / "stereo.wav"
    _write_silent_wav(input_path, channels=2)
    model_dir = tmp_path / "models"
    output_dir = tmp_path / "out"
    loads = []

    class CacheSeparator:
        def __init__(self, *args, output_dir=None, **kwargs):
            self.output_dir = Path(output_dir) if output_dir else Path.cwd()
            self.last_perf_metrics = {}

        def load_model(self, model_filename):
            loads.append(model_filename)
            return None

        def separate(self, audio_path):
            output = self.output_dir / "stereo_(vocals).wav"
            _write_silent_wav(output, channels=2)
            return [str(output)]

    _install_fake_separator(monkeypatch, CacheSeparator)
    engine = MlxSeparatorEngine(model_dir=str(model_dir))
    monkeypatch.setattr(engine, "runtime_stats", lambda: {})
    monkeypatch.setattr(engine, "model_cache", lambda: {"items": [], "totalBytes": 0, "modelDir": str(model_dir)})

    job = SeparationJob(
        input_path=str(input_path),
        output_dir=str(output_dir),
        model_filename="BS-Roformer-SW.ckpt",
        preset="kirtan_pro",
        output_format="WAV",
    )

    first = engine.separate(job, progress=lambda *_args: None)
    second = engine.separate(job, progress=lambda *_args: None)

    # Same fingerprint -> only the first (cold) run loads the model.
    assert len(loads) == 1
    assert first["modelHot"] is False
    assert second["modelHot"] is True


def test_engine_reloads_separator_when_fingerprint_changes(tmp_path, monkeypatch):
    input_path = tmp_path / "stereo.wav"
    _write_silent_wav(input_path, channels=2)
    model_dir = tmp_path / "models"
    output_dir = tmp_path / "out"
    loads = []

    class CacheSeparator:
        def __init__(self, *args, output_dir=None, **kwargs):
            self.output_dir = Path(output_dir) if output_dir else Path.cwd()
            self.last_perf_metrics = {}

        def load_model(self, model_filename):
            loads.append(model_filename)
            return None

        def separate(self, audio_path):
            output = self.output_dir / "stereo_(vocals).wav"
            _write_silent_wav(output, channels=2)
            return [str(output)]

    _install_fake_separator(monkeypatch, CacheSeparator)
    engine = MlxSeparatorEngine(model_dir=str(model_dir))
    monkeypatch.setattr(engine, "runtime_stats", lambda: {})
    monkeypatch.setattr(engine, "model_cache", lambda: {"items": [], "totalBytes": 0, "modelDir": str(model_dir)})

    base = dict(
        input_path=str(input_path),
        output_dir=str(output_dir),
        model_filename="BS-Roformer-SW.ckpt",
        preset="kirtan_pro",
        output_format="WAV",
    )
    engine.separate(SeparationJob(**base, mdxc_segment_size=512), progress=lambda *_args: None)
    # Different segment size -> different fingerprint -> cold reload.
    engine.separate(SeparationJob(**base, mdxc_segment_size=1024), progress=lambda *_args: None)

    assert len(loads) == 2


def test_engine_invalidates_separator_cache_on_cancel(tmp_path, monkeypatch):
    input_path = tmp_path / "stereo.wav"
    _write_silent_wav(input_path, channels=2)
    model_dir = tmp_path / "models"
    output_dir = tmp_path / "out"
    loads = []

    class CacheSeparator:
        def __init__(self, *args, output_dir=None, **kwargs):
            self.output_dir = Path(output_dir) if output_dir else Path.cwd()
            self.last_perf_metrics = {}

        def load_model(self, model_filename):
            loads.append(model_filename)
            return None

        def separate(self, audio_path):
            output = self.output_dir / "stereo_(vocals).wav"
            _write_silent_wav(output, channels=2)
            return [str(output)]

    _install_fake_separator(monkeypatch, CacheSeparator)
    engine = MlxSeparatorEngine(model_dir=str(model_dir))
    monkeypatch.setattr(engine, "runtime_stats", lambda: {})
    monkeypatch.setattr(engine, "model_cache", lambda: {"items": [], "totalBytes": 0, "modelDir": str(model_dir)})

    job = SeparationJob(
        input_path=str(input_path),
        output_dir=str(output_dir),
        model_filename="BS-Roformer-SW.ckpt",
        preset="kirtan_pro",
        output_format="WAV",
    )
    engine.separate(job, progress=lambda *_args: None)
    engine.cancel_current("User aborted")
    engine.separate(job, progress=lambda *_args: None)

    # Cancel invalidated the cache, so the second run is cold again.
    assert len(loads) == 2


def test_engine_separator_fingerprint_distinguishes_parameters():
    job_a = SeparationJob(
        input_path="/tmp/a.wav",
        output_dir="/tmp/out",
        model_filename="BS-Roformer-SW.ckpt",
        preset="kirtan_pro",
        mdxc_segment_size=512,
        mdxc_batch_size=1,
        speed_mode="latency_safe_v3",
    )
    job_b = SeparationJob(
        input_path="/tmp/b.wav",
        output_dir="/tmp/out",
        model_filename="BS-Roformer-SW.ckpt",
        preset="kirtan_pro",
        mdxc_segment_size=1024,
        mdxc_batch_size=1,
        speed_mode="latency_safe_v3",
    )
    engine = MlxSeparatorEngine(model_dir="/tmp/models")

    assert engine._separator_fingerprint(job_a) != engine._separator_fingerprint(job_b)
    assert engine._separator_fingerprint(job_a) == engine._separator_fingerprint(job_a)


def test_engine_runtime_stats_reports_model_hot_flag(tmp_path):
    engine = MlxSeparatorEngine(model_dir=str(tmp_path / "models"))
    assert engine.runtime_stats()["modelHot"] is False

    engine._cached_separator = object()
    assert engine.runtime_stats()["modelHot"] is True


def _install_fake_separator(monkeypatch, separator_class):
    monkeypatch.setitem(
        sys.modules,
        "mlx_audio_separator",
        types.SimpleNamespace(Separator=separator_class),
    )


def _write_silent_wav(path: Path, channels: int, sample_rate: int = 44_100, sample_width: int = 2):
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(channels)
        wav.setsampwidth(sample_width)
        wav.setframerate(sample_rate)
        wav.writeframes((b"\0" * sample_width) * channels * 4410)


def _write_float_wav(path: Path, channels: int, sample_rate: int):
    raw_path = path.with_suffix(".f32le")
    raw_path.write_bytes(b"\0" * 4 * channels * max(1, sample_rate // 10))
    try:
        subprocess.run(
            [
                "ffmpeg",
                "-hide_banner",
                "-loglevel",
                "error",
                "-y",
                "-f",
                "f32le",
                "-ar",
                str(sample_rate),
                "-ac",
                str(channels),
                "-i",
                str(raw_path),
                "-c:a",
                "pcm_f32le",
                str(path),
            ],
            check=True,
        )
    finally:
        raw_path.unlink(missing_ok=True)


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


def _audio_sample_rate(path: Path) -> int:
    output = subprocess.check_output(
        [
            "ffprobe",
            "-v",
            "error",
            "-select_streams",
            "a:0",
            "-show_entries",
            "stream=sample_rate",
            "-of",
            "default=noprint_wrappers=1:nokey=1",
            str(path),
        ],
        text=True,
    )
    return int(output.strip())


def _audio_bit_depth(path: Path) -> int:
    output = subprocess.check_output(
        [
            "ffprobe",
            "-v",
            "error",
            "-select_streams",
            "a:0",
            "-show_entries",
            "stream=bits_per_raw_sample,bits_per_sample",
            "-of",
            "json",
            str(path),
        ],
        text=True,
    )
    stream = json.loads(output)["streams"][0]
    value = stream.get("bits_per_raw_sample") or stream.get("bits_per_sample")
    if value and str(value).isdigit():
        return int(value)
    sample_format = str(stream.get("sample_fmt") or "").lower().rstrip("p")
    if sample_format == "flt":
        return 32
    if sample_format == "dbl":
        return 64
    digits = "".join(character for character in sample_format if character.isdigit())
    return int(digits or 0)


def _audio_codec(path: Path) -> str:
    output = subprocess.check_output(
        [
            "ffprobe",
            "-v",
            "error",
            "-select_streams",
            "a:0",
            "-show_entries",
            "stream=codec_name",
            "-of",
            "default=noprint_wrappers=1:nokey=1",
            str(path),
        ],
        text=True,
    )
    return output.strip()


def _audio_tags(path: Path) -> dict:
    output = subprocess.check_output(
        [
            "ffprobe",
            "-v",
            "error",
            "-show_entries",
            "format_tags",
            "-of",
            "json",
            str(path),
        ],
        text=True,
    )
    return json.loads(output)["format"]["tags"]
