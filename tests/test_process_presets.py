from kirtan_backend.process_presets import PROCESS_PRESETS, process_preset_list


def test_process_presets_expose_fast_heavy_and_extreme_benchmark_modes():
    assert list(PROCESS_PRESETS) == ["builtin.fast", "builtin.heavy", "builtin.extreme"]
    assert PROCESS_PRESETS["builtin.fast"]["settings"]["mdxcSegmentSize"] == 512
    assert PROCESS_PRESETS["builtin.heavy"]["settings"]["mdxcSegmentSize"] == 1024
    assert PROCESS_PRESETS["builtin.extreme"]["settings"]["mdxcSegmentSize"] == 4096
    assert PROCESS_PRESETS["builtin.extreme"]["settings"]["mdxcOverrideModelSegmentSize"] is True
    assert [preset["title"] for preset in process_preset_list()] == [
        "Fast 512",
        "Heavy 1024",
        "Extreme 4096",
    ]
