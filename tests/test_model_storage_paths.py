from pathlib import Path

from kirtan_backend.server import build_parser


def test_backend_default_model_dir_uses_user_visible_sound_folder(monkeypatch):
    monkeypatch.delenv("KIRTAN_SPLITTER_MODEL_DIR", raising=False)
    monkeypatch.setenv("HOME", "/Users/pavan")

    args = build_parser().parse_args([])

    assert Path(args.model_dir) == Path("/Users/pavan/AI_LOCAL_MODELS/Sound/AuraSplitter")
