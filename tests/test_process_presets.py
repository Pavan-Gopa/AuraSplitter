from kirtan_backend.process_presets import PROCESS_PRESETS, process_preset_list


def test_process_presets_expose_fast_heavy_and_extreme_benchmark_modes():
    assert list(PROCESS_PRESETS) == [
        "builtin.fast",
        "builtin.heavy",
        "builtin.extreme",
        "metal.fast",
        "metal.max",
    ]
    assert PROCESS_PRESETS["builtin.fast"]["settings"]["mdxcSegmentSize"] == 512
    assert PROCESS_PRESETS["builtin.heavy"]["settings"]["mdxcSegmentSize"] == 1024
    assert PROCESS_PRESETS["builtin.extreme"]["settings"]["mdxcSegmentSize"] == 4096
    assert PROCESS_PRESETS["builtin.extreme"]["settings"]["mdxcOverrideModelSegmentSize"] is True
    assert [preset["title"] for preset in process_preset_list()] == [
        "Fast 512",
        "Heavy 1024",
        "Extreme 4096",
        "Metal Fast",
        "Metal Max",
    ]


def test_metal_fast_preset_uses_safe_experimental_flags_without_compile():
    flags = PROCESS_PRESETS["metal.fast"]["settings"]["performanceFlags"]
    assert flags["experimental_roformer_fast_norm"] is True
    assert flags["experimental_roformer_grouped_band_split"] is True
    assert flags["experimental_roformer_grouped_mask_estimator"] is True
    assert flags["experimental_roformer_fused_overlap_add"] is True
    assert flags["experimental_flac_fast_write"] is True
    # Metal Fast must not enable graph compile or cold auto_tune.
    assert "experimental_roformer_compile_fullgraph" not in flags
    assert "auto_tune_batch" not in flags


def test_metal_max_preset_enables_compile_flags_and_keeps_auto_tune_off():
    flags = PROCESS_PRESETS["metal.max"]["settings"]["performanceFlags"]
    assert flags["experimental_roformer_compile_fullgraph"] is True
    assert flags["experimental_compile_model_forward"] is True
    assert "auto_tune_batch" not in flags
