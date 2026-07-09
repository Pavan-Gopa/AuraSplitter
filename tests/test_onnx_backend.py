import sys
import types
from pathlib import Path

import numpy as np
import soundfile as sf

from kirtan_backend.onnx_backend import DemucsOnnxBackend, PolarFormerOnnxBackend, onnx_runtime_status


def test_onnx_runtime_status_reports_available_providers(monkeypatch):
    fake_ort = types.SimpleNamespace(
        __version__="1.27.0",
        get_available_providers=lambda: ["CoreMLExecutionProvider", "CPUExecutionProvider"],
    )
    monkeypatch.setitem(sys.modules, "onnxruntime", fake_ort)

    status = onnx_runtime_status()

    assert status["available"] is True
    assert status["version"] == "1.27.0"
    assert status["preferredProvider"] == "CoreMLExecutionProvider"


def test_demucs_onnx_backend_uses_project_model_cache_and_writes_stem_files(tmp_path, monkeypatch):
    input_path = tmp_path / "mix.wav"
    input_path.write_bytes(b"fake wav")
    output_dir = tmp_path / "out"
    model_dir = tmp_path / "models"
    calls = []

    def fake_separate(input, output_dir, **kwargs):
        calls.append((Path(input), Path(output_dir), kwargs))
        Path(output_dir).mkdir(parents=True, exist_ok=True)
        for stem in ["vocals", "drums", "bass", "other"]:
            (Path(output_dir) / f"{stem}.wav").write_bytes(stem.encode())
        return {"vocals": object(), "drums": object(), "bass": object(), "other": object()}

    monkeypatch.setitem(sys.modules, "demucs_onnx", types.SimpleNamespace(separate=fake_separate))
    backend = DemucsOnnxBackend(model_dir=str(model_dir))

    files = backend.separate(
        input_path=str(input_path),
        output_dir=str(output_dir),
        output_format="WAV",
        model="htdemucs_ft",
    )

    assert [Path(file).name for file in files] == ["bass.wav", "drums.wav", "other.wav", "vocals.wav"]
    assert calls[0][0] == input_path
    assert calls[0][1] == output_dir
    assert calls[0][2]["cache_dir"] == str(model_dir / "onnx")
    assert calls[0][2]["providers"] == "auto"
    assert calls[0][2]["progress"] is False
    assert calls[0][2]["output_format"] == "wav"


def test_polarformer_onnx_backend_writes_vocals_and_instrumental_files(tmp_path, monkeypatch):
    input_path = tmp_path / "mix.wav"
    sample_rate = 44100
    samples = np.zeros((4096, 2), dtype=np.float32)
    samples[:, 0] = 0.1
    samples[:, 1] = -0.1
    sf.write(input_path, samples, sample_rate)

    output_dir = tmp_path / "out"
    model_dir = tmp_path / "models"
    model_dir.mkdir()
    (model_dir / "bs_polarformer_fp16.onnx").write_bytes(b"fake onnx")
    (model_dir / "model_bs_polarformer_float16.yaml").write_text(
        """
audio:
  sample_rate: 44100
model:
  stereo: true
  stft_n_fft: 16
  stft_hop_length: 8
  stft_win_length: 16
  stft_normalized: false
inference:
  chunk_size: 512
  batch_size: 1
  num_overlap: 2
""",
        encoding="utf-8",
    )

    class FakeInferenceSession:
        def __init__(self, path, providers):
            self.path = path
            self.providers = providers

        def run(self, _outputs, inputs):
            features = inputs["stft_features"]
            frames = features.shape[1]
            feature_count = features.shape[2] // 2
            mask = np.zeros((1, 1, feature_count, frames, 2), dtype=np.float32)
            mask[..., 0] = 1.0
            return [mask]

    fake_ort = types.SimpleNamespace(
        get_available_providers=lambda: ["CPUExecutionProvider"],
        InferenceSession=FakeInferenceSession,
    )
    monkeypatch.setitem(sys.modules, "onnxruntime", fake_ort)

    backend = PolarFormerOnnxBackend(model_dir=str(model_dir))
    files = backend.separate(
        input_path=str(input_path),
        output_dir=str(output_dir),
        output_format="WAV",
        model="bs_polarformer_fp16.onnx",
        config_filename="model_bs_polarformer_float16.yaml",
    )

    assert [Path(file).name for file in files] == ["vocals.wav", "instrumental.wav"]
    assert all(Path(file).exists() for file in files)


def test_polarformer_onnx_backend_requests_coreml_all_compute_units_with_cache(tmp_path, monkeypatch):
    model_dir = tmp_path / "models"
    model_dir.mkdir()
    model_path = model_dir / "bs_polarformer_fp16.onnx"
    model_path.write_bytes(b"fake onnx")
    calls = []

    class FakeInferenceSession:
        def __init__(self, path, providers):
            calls.append((path, providers))

    fake_ort = types.SimpleNamespace(
        get_available_providers=lambda: ["CoreMLExecutionProvider", "CPUExecutionProvider"],
        InferenceSession=FakeInferenceSession,
    )
    monkeypatch.setitem(sys.modules, "onnxruntime", fake_ort)

    backend = PolarFormerOnnxBackend(model_dir=str(model_dir))
    backend._create_session(model_path)

    assert calls[0][0] == str(model_path)
    providers = calls[0][1]
    assert providers[0][0] == "CoreMLExecutionProvider"
    assert providers[0][1]["MLComputeUnits"] == "ALL"
    assert providers[0][1]["ModelFormat"] == "MLProgram"
    assert providers[0][1]["ModelCacheDirectory"] == str(model_dir / "onnx" / "coreml-cache")
    assert providers[-1] == "CPUExecutionProvider"


def test_polarformer_onnx_backend_reports_real_chunk_progress(tmp_path, monkeypatch):
    input_path = tmp_path / "mix.wav"
    sample_rate = 44100
    samples = np.zeros((1536, 2), dtype=np.float32)
    samples[:, 0] = 0.1
    samples[:, 1] = -0.1
    sf.write(input_path, samples, sample_rate)

    output_dir = tmp_path / "out"
    model_dir = tmp_path / "models"
    model_dir.mkdir()
    (model_dir / "bs_polarformer_fp16.onnx").write_bytes(b"fake onnx")
    (model_dir / "model_bs_polarformer_float16.yaml").write_text(
        """
audio:
  sample_rate: 44100
model:
  stereo: true
  stft_n_fft: 16
  stft_hop_length: 8
  stft_win_length: 16
  stft_normalized: false
inference:
  chunk_size: 512
  batch_size: 1
  num_overlap: 2
""",
        encoding="utf-8",
    )

    class FakeInferenceSession:
        def __init__(self, path, providers):
            self.path = path
            self.providers = providers

        def run(self, _outputs, inputs):
            features = inputs["stft_features"]
            frames = features.shape[1]
            feature_count = features.shape[2] // 2
            mask = np.zeros((1, 1, feature_count, frames, 2), dtype=np.float32)
            mask[..., 0] = 1.0
            return [mask]

    fake_ort = types.SimpleNamespace(
        get_available_providers=lambda: ["CPUExecutionProvider"],
        InferenceSession=FakeInferenceSession,
    )
    monkeypatch.setitem(sys.modules, "onnxruntime", fake_ort)

    progress_events = []
    backend = PolarFormerOnnxBackend(model_dir=str(model_dir))
    backend.separate(
        input_path=str(input_path),
        output_dir=str(output_dir),
        output_format="WAV",
        model="bs_polarformer_fp16.onnx",
        config_filename="model_bs_polarformer_float16.yaml",
        progress_callback=lambda stage, message, value: progress_events.append((stage, message, value)),
        progress_start=0.08,
        progress_end=0.92,
    )

    chunk_events = [event for event in progress_events if event[0] == "separating"]
    assert len(chunk_events) >= 2
    assert "chunk" in chunk_events[0][1].lower()
    assert chunk_events[-1][2] == 0.92
    assert [event[2] for event in chunk_events] == sorted(event[2] for event in chunk_events)
