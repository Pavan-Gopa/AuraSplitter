from kirtan_backend.process_presets import PROCESS_PRESETS, process_preset_list


def test_process_presets_are_named_without_digits():
    assert list(PROCESS_PRESETS) == [
        "builtin.default",
        "builtin.fast",
        "builtin.heavy",
        "builtin.max",
        "builtin.extreme",
    ]
    titles = [preset["title"] for preset in process_preset_list()]
    assert titles == ["Default", "Fast", "Heavy", "Max", "Extreme"]
    for title in titles:
        assert not any(ch.isdigit() for ch in title)


def test_process_preset_segment_sizes_scale_default_to_extreme():
    assert PROCESS_PRESETS["builtin.default"]["settings"]["mdxcSegmentSize"] == 256
    assert PROCESS_PRESETS["builtin.fast"]["settings"]["mdxcSegmentSize"] == 512
    assert PROCESS_PRESETS["builtin.heavy"]["settings"]["mdxcSegmentSize"] == 1024
    assert PROCESS_PRESETS["builtin.max"]["settings"]["mdxcSegmentSize"] == 2048
    assert PROCESS_PRESETS["builtin.extreme"]["settings"]["mdxcSegmentSize"] == 4096
    assert PROCESS_PRESETS["builtin.extreme"]["settings"]["mdxcOverrideModelSegmentSize"] is True
    # Removed experimental Metal presets from the built-in list.
    assert "metal.fast" not in PROCESS_PRESETS
    assert "metal.max" not in PROCESS_PRESETS
