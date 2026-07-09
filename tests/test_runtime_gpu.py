from kirtan_backend import runtime


IOREG_GPU_SAMPLE = """
+-o AGXAcceleratorG16G  <class AGXAcceleratorG16G, id 0x100000453, registered, matched, active, busy 0 (684 ms), retain 96>
  |   "PerformanceStatistics" = {"In use system memory (driver)"=0,"Alloc system memory"=7178698752,"Tiler Utilization %"=74,"Renderer Utilization %"=73,"Device Utilization %"=74,"In use system memory"=2704703488}
  |   "gpu-core-count" = 10
"""


def test_parse_ioreg_gpu_stats_reports_device_utilization_and_memory():
    result = runtime.parse_ioreg_gpu_stats(IOREG_GPU_SAMPLE)

    assert result["status"] == "ok"
    assert result["source"] == "ioreg"
    assert result["utilizationPercent"] == 74.0
    assert result["gpuCoreCount"] == 10
    assert result["rendererUtilizationPercent"] == 73.0
    assert result["tilerUtilizationPercent"] == 74.0
    assert result["inUseSystemMemoryBytes"] == 2704703488


def test_gpu_stats_falls_back_to_ioreg_when_powermetrics_is_unavailable(monkeypatch):
    monkeypatch.setattr(
        runtime,
        "try_powermetrics_gpu",
        lambda: {"status": "unavailable: CalledProcessError", "source": "powermetrics"},
    )
    monkeypatch.setattr(
        runtime,
        "try_ioreg_gpu",
        lambda: {"status": "ok", "source": "ioreg", "utilizationPercent": 74.0},
        raising=False,
    )

    result = runtime.gpu_stats()

    assert result["status"] == "ok"
    assert result["source"] == "ioreg"
    assert result["utilizationPercent"] == 74.0


def test_delete_model_cache_item_removes_file_and_reports_remaining_cache(tmp_path):
    model_dir = tmp_path / "models"
    model_dir.mkdir()
    checkpoint = model_dir / "BS-Roformer-SW.ckpt"
    converted = model_dir / "BS-Roformer-SW.safetensors"
    checkpoint.write_bytes(b"checkpoint")
    converted.write_bytes(b"converted")

    result = runtime.delete_model_cache_item(str(model_dir), str(converted))

    assert not converted.exists()
    assert checkpoint.exists()
    assert result["deleted"]["filename"] == "BS-Roformer-SW.safetensors"
    assert result["totalBytes"] == len(b"checkpoint")
    assert [item["filename"] for item in result["items"]] == ["BS-Roformer-SW.ckpt"]


def test_model_cache_groups_hide_config_files_and_report_installed_model(tmp_path):
    model_dir = tmp_path / "models"
    model_dir.mkdir()
    checkpoint = model_dir / "BS-Roformer-SW.ckpt"
    converted = model_dir / "BS-Roformer-SW.safetensors"
    config = model_dir / "BS-Roformer-SW.yaml"
    checkpoint.write_bytes(b"source-checkpoint")
    converted.write_bytes(b"converted-weights")
    config.write_text("audio:\n  sample_rate: 44100\n", encoding="utf-8")

    result = runtime.model_cache(str(model_dir))

    group = {item["id"]: item for item in result["groups"]}["BS-Roformer-SW"]
    assert group["converted"] is True
    assert group["hasSource"] is True
    assert group["sourceRemoved"] is False
    assert group["canDeleteSource"] is True
    assert group["sourceBytes"] == len(b"source-checkpoint")
    assert group["convertedBytes"] == len(b"converted-weights")
    assert group["configBytes"] == config.stat().st_size
    assert [file["kind"] for file in group["files"]] == ["checkpoint", "converted"]


def test_model_cache_groups_attach_catalog_metadata_for_sidebar_details(tmp_path):
    model_dir = tmp_path / "models"
    model_dir.mkdir()
    checkpoint = model_dir / "bs_roformer_voc_hyperacev2.ckpt"
    converted = model_dir / "bs_roformer_voc_hyperacev2.safetensors"
    config = model_dir / "bs_roformer_voc_hyperacev2.yaml"
    checkpoint.write_bytes(b"source-checkpoint")
    converted.write_bytes(b"converted-weights")
    config.write_text("audio:\n  sample_rate: 44100\n", encoding="utf-8")

    result = runtime.model_cache(str(model_dir))

    group = {item["displayName"]: item for item in result["groups"]}["Kirtan Vocal Pro"]
    assert group["displayName"] == "Kirtan Vocal Pro"
    assert group["technicalName"] == "HyperACE v2 Vocal"
    assert group["architecture"] == "BS-RoFormer"
    assert group["backend"] == "MLX"
    assert group["license"]
    assert group["sourceURL"] == "https://huggingface.co/pcunwa/BS-Roformer-HyperACE"
    assert group["summary"]
    assert group["localState"] == "installed"


def test_model_cache_groups_include_available_models_that_are_not_downloaded(tmp_path):
    model_dir = tmp_path / "models"
    model_dir.mkdir()

    result = runtime.model_cache(str(model_dir))
    groups = {group["displayName"]: group for group in result["groups"]}

    assert groups["Kirtan Vocal Elite"]["technicalName"] == "Leap Xe Vocal"
    assert groups["Kirtan Vocal Elite"]["converted"] is False
    assert groups["Kirtan Vocal Elite"]["hasSource"] is False
    assert groups["Kirtan Vocal Elite"]["localState"] == "not_downloaded"
    assert groups["Kirtan Vocal Elite"]["totalBytes"] == 0
    assert groups["Kirtan Vocal Max"]["technicalName"] == "BS PolarFormer 124-band"
    assert groups["Kirtan Vocal Max"]["architecture"] == "BS-PolarFormer"
    assert groups["Kirtan Vocal Max"]["backend"] == "ONNX/CoreML"
    assert groups["Kirtan Vocal Max"]["localState"] == "not_downloaded"
    assert groups["Kirtan Stems Pro"]["backend"] == "ONNX/CoreML"


def test_model_cache_groups_include_every_header_preset_name(tmp_path):
    from kirtan_backend.presets import PRESETS

    model_dir = tmp_path / "models"
    model_dir.mkdir()

    result = runtime.model_cache(str(model_dir))
    sidebar_titles = {group["displayName"] for group in result["groups"]}
    header_titles = {preset.title for preset in PRESETS.values()}

    assert "Kirtan Clean Split" in sidebar_titles
    assert header_titles.issubset(sidebar_titles)
    assert {group["displayName"]: group for group in result["groups"]}["Kirtan Clean Split"]["technicalName"] == "BS-Roformer-Viperx-1297"


def test_model_cache_groups_include_usage_count_from_render_history(tmp_path):
    from kirtan_backend.render_estimates import record_render_benchmark

    model_dir = tmp_path / "models"
    model_dir.mkdir()
    record_render_benchmark(
        str(model_dir),
        {
            "modelFilename": "BS-Roformer-SW.ckpt",
            "modelPresetID": "kirtan_pro",
            "processPresetID": "builtin.fast",
            "elapsedSeconds": 300,
            "audioDurationSeconds": 300,
        },
    )
    record_render_benchmark(
        str(model_dir),
        {
            "modelFilename": "BS-Roformer-SW.ckpt",
            "modelPresetID": "kirtan_pro",
            "processPresetID": "builtin.heavy",
            "elapsedSeconds": 450,
            "audioDurationSeconds": 300,
        },
    )

    result = runtime.model_cache(str(model_dir))
    group = {item["displayName"]: item for item in result["groups"]}["Kirtan Pro"]

    assert group["usageCount"] == 2


def test_model_cache_groups_ignore_config_only_files(tmp_path):
    model_dir = tmp_path / "models"
    model_dir.mkdir()
    (model_dir / "orphan.yaml").write_text("audio:\n  sample_rate: 44100\n", encoding="utf-8")

    result = runtime.model_cache(str(model_dir))

    assert all(group["id"] != "orphan" for group in result["groups"])


def test_delete_model_group_source_replaces_checkpoint_with_placeholder(tmp_path):
    model_dir = tmp_path / "models"
    model_dir.mkdir()
    checkpoint = model_dir / "BS-Roformer-SW.ckpt"
    converted = model_dir / "BS-Roformer-SW.safetensors"
    config = model_dir / "BS-Roformer-SW.yaml"
    source_bytes = b"x" * 4096
    checkpoint.write_bytes(source_bytes)
    converted.write_bytes(b"converted-weights")
    config.write_text("audio:\n  sample_rate: 44100\n", encoding="utf-8")

    result = runtime.delete_model_group_source(str(model_dir), "BS-Roformer-SW")

    assert checkpoint.exists()
    assert checkpoint.stat().st_size < len(source_bytes)
    assert converted.exists()
    assert config.exists()
    group = {item["id"]: item for item in result["groups"]}["BS-Roformer-SW"]
    assert group["id"] == "BS-Roformer-SW"
    assert group["converted"] is True
    assert group["hasSource"] is False
    assert group["sourceRemoved"] is True
    assert group["sourceBytes"] == 0
    assert group["canDeleteSource"] is False
    assert result["deleted"]["filename"] == "BS-Roformer-SW.ckpt"
    assert result["deleted"]["replacedWithPlaceholder"] is True


def test_delete_model_group_source_requires_converted_weights_and_config(tmp_path):
    model_dir = tmp_path / "models"
    model_dir.mkdir()
    checkpoint = model_dir / "BS-Roformer-SW.ckpt"
    checkpoint.write_bytes(b"source-checkpoint")

    try:
        runtime.delete_model_group_source(str(model_dir), "BS-Roformer-SW")
    except ValueError as exc:
        assert "converted weights and config" in str(exc)
    else:
        raise AssertionError("Expected ValueError")

    assert checkpoint.read_bytes() == b"source-checkpoint"


def test_delete_model_cache_item_rejects_paths_outside_model_dir(tmp_path):
    model_dir = tmp_path / "models"
    model_dir.mkdir()
    outside = tmp_path / "outside.safetensors"
    outside.write_bytes(b"do not delete")

    try:
        runtime.delete_model_cache_item(str(model_dir), str(outside))
    except ValueError as exc:
        assert "outside model cache" in str(exc)
    else:
        raise AssertionError("Expected ValueError")

    assert outside.exists()
