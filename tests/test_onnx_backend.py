import sys
import types
from pathlib import Path

from kirtan_backend.onnx_backend import DemucsOnnxBackend, onnx_runtime_status


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
