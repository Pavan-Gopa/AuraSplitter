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
