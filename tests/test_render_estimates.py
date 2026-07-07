from kirtan_backend.render_estimates import (
    estimate_render_time,
    load_render_benchmarks,
    record_render_benchmark,
)


def test_render_estimate_is_unavailable_without_calibration(tmp_path):
    result = estimate_render_time(
        str(tmp_path),
        model_filename="BS-Roformer-SW.ckpt",
        process_preset_id="builtin.fast",
        audio_duration_seconds=600,
        gpu_core_count=10,
    )

    assert result["status"] == "unavailable"
    assert result["reason"] == "no_calibration"
    assert result["estimatedSeconds"] is None


def test_render_estimate_records_sample_and_scales_by_duration_and_gpu(tmp_path):
    recorded = record_render_benchmark(
        str(tmp_path),
        {
            "modelFilename": "BS-Roformer-SW.ckpt",
            "modelPresetID": "kirtan_pro",
            "processPresetID": "builtin.heavy",
            "processPresetTitle": "Heavy 1024",
            "elapsedSeconds": 900,
            "audioDurationSeconds": 450,
            "gpuCoreCount": 10,
            "settings": {"mdxcSegmentSize": 1024},
        },
    )

    result = estimate_render_time(
        str(tmp_path),
        model_filename="BS-Roformer-SW.ckpt",
        process_preset_id="builtin.heavy",
        audio_duration_seconds=900,
        gpu_core_count=20,
    )

    assert recorded["secondsPerAudioSecond"] == 2.0
    assert result["status"] == "calibrated"
    assert result["sampleCount"] == 1
    assert result["estimatedSeconds"] == 900.0
    assert result["baselineGpuCoreCount"] == 10
    assert result["targetGpuCoreCount"] == 20


def test_render_estimate_uses_matching_process_preset_samples(tmp_path):
    record_render_benchmark(
        str(tmp_path),
        {
            "modelFilename": "BS-Roformer-SW.ckpt",
            "modelPresetID": "kirtan_pro",
            "processPresetID": "builtin.fast",
            "processPresetTitle": "Fast 512",
            "elapsedSeconds": 300,
            "audioDurationSeconds": 300,
            "gpuCoreCount": 10,
        },
    )
    record_render_benchmark(
        str(tmp_path),
        {
            "modelFilename": "BS-Roformer-SW.ckpt",
            "modelPresetID": "kirtan_pro",
            "processPresetID": "builtin.extreme",
            "processPresetTitle": "Extreme 4096",
            "elapsedSeconds": 1200,
            "audioDurationSeconds": 300,
            "gpuCoreCount": 10,
        },
    )

    result = estimate_render_time(
        str(tmp_path),
        model_filename="BS-Roformer-SW.ckpt",
        process_preset_id="builtin.extreme",
        audio_duration_seconds=600,
        gpu_core_count=10,
    )

    assert result["status"] == "calibrated"
    assert result["sampleCount"] == 1
    assert result["estimatedSeconds"] == 2400.0
    assert load_render_benchmarks(str(tmp_path))[1]["processPresetTitle"] == "Extreme 4096"
