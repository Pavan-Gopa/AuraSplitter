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
