import XCTest
@testable import KirtanSplitterApp

final class ProcessSettingsPresetTests: XCTestCase {
    func testSnapshotAppliesProcessSettingsWithoutChangingModelChoice() {
        var source = SeparationSettings()
        source.outputFormat = "FLAC"
        source.speedMode = "default"
        source.chunkDuration = 0
        source.mdxcSegmentSize = 1024
        source.mdxcOverlap = 12
        source.mdxcBatchSize = 3
        source.mdxcOverrideModelSegmentSize = true
        source.saveConvertedSafetensors = false

        var target = SeparationSettings()
        target.presetID = "viperx_vocal"
        target.modelOverride = "custom.ckpt"

        ProcessSettingsSnapshot(settings: source).apply(to: &target)

        XCTAssertEqual(target.presetID, "viperx_vocal")
        XCTAssertEqual(target.modelOverride, "custom.ckpt")
        XCTAssertEqual(target.outputFormat, "FLAC")
        XCTAssertEqual(target.speedMode, "default")
        XCTAssertEqual(target.chunkDuration, 0)
        XCTAssertEqual(target.mdxcSegmentSize, 1024)
        XCTAssertEqual(target.mdxcOverlap, 12)
        XCTAssertEqual(target.mdxcBatchSize, 3)
        XCTAssertTrue(target.mdxcOverrideModelSegmentSize)
        XCTAssertFalse(target.saveConvertedSafetensors)
    }

    func testStorePersistsCustomPresetsAndKeepsBuiltIns() {
        let suiteName = "ProcessSettingsPresetTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ProcessSettingsPresetStore(defaults: defaults)
        let initialBuiltInCount = store.presets.filter(\.isBuiltIn).count

        let saved = store.saveCustomPreset(named: "My 1024", settings: presetSettings(segmentSize: 1024))
        let reloaded = ProcessSettingsPresetStore(defaults: defaults)

        XCTAssertEqual(reloaded.presets.filter(\.isBuiltIn).count, initialBuiltInCount)
        XCTAssertEqual(reloaded.preset(id: saved.id)?.title, "My 1024")
        XCTAssertEqual(reloaded.preset(id: saved.id)?.snapshot.mdxcSegmentSize, 1024)
    }

    func testBuiltInPresetsIncludeExtremeRenderPreset() {
        let extreme = ProcessSettingsPreset.builtIn.first { $0.id == "builtin.extreme" }

        XCTAssertEqual(extreme?.title, "Extreme 4096")
        XCTAssertEqual(extreme?.snapshot.mdxcSegmentSize, 4096)
        XCTAssertEqual(extreme?.snapshot.mdxcOverlap, 12)
        XCTAssertEqual(extreme?.snapshot.mdxcBatchSize, 1)
        XCTAssertTrue(extreme?.snapshot.mdxcOverrideModelSegmentSize == true)
    }

    func testBuiltInMetalPresetsExistAndCarryPerformanceFlags() {
        let fast = ProcessSettingsPreset.builtIn.first { $0.id == "metal.fast" }
        let max = ProcessSettingsPreset.builtIn.first { $0.id == "metal.max" }

        XCTAssertEqual(fast?.title, "Metal Fast")
        XCTAssertEqual(max?.title, "Metal Max")

        XCTAssertTrue(fast?.snapshot.performanceFlags["experimental_roformer_fast_norm"] == true)
        XCTAssertNil(fast?.snapshot.performanceFlags["experimental_roformer_compile_fullgraph"])

        XCTAssertTrue(max?.snapshot.performanceFlags["experimental_roformer_compile_fullgraph"] == true)
        // auto_tune_batch must never be enabled by a Metal preset.
        XCTAssertNil(max?.snapshot.performanceFlags["auto_tune_batch"])
    }

    func testSnapshotAppliesPerformanceFlagsWithoutChangingModelChoice() {
        var source = SeparationSettings()
        source.performanceFlags = ["experimental_roformer_fast_norm": true]

        var target = SeparationSettings()
        target.presetID = "viperx_vocal"
        target.modelOverride = "custom.ckpt"

        ProcessSettingsSnapshot(settings: source).apply(to: &target)

        XCTAssertEqual(target.presetID, "viperx_vocal")
        XCTAssertEqual(target.modelOverride, "custom.ckpt")
        XCTAssertEqual(target.performanceFlags, ["experimental_roformer_fast_norm": true])
    }

    func testSnapshotDecodesWhenPerformanceFlagsAbsent(legacyData: Data? = nil) {
        // Pre-K1 custom presets were persisted without performanceFlags.
        let json = """
        {
          "id": "custom.legacy",
          "title": "Legacy",
          "isBuiltIn": false,
          "snapshot": {
            "outputFormat": "WAV",
            "speedMode": "latency_safe_v3",
            "chunkDuration": 30,
            "mdxcSegmentSize": 512,
            "mdxcOverlap": 8,
            "mdxcBatchSize": 1,
            "mdxcOverrideModelSegmentSize": false,
            "saveConvertedSafetensors": true
          }
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let preset = try? decoder.decode(ProcessSettingsPreset.self, from: json)
        XCTAssertEqual(preset?.snapshot.performanceFlags, [:])
    }

    private func presetSettings(segmentSize: Int) -> SeparationSettings {
        var settings = SeparationSettings()
        settings.mdxcSegmentSize = segmentSize
        return settings
    }
}
