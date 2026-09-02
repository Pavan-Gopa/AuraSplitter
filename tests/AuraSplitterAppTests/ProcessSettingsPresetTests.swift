import XCTest
@testable import AuraSplitterApp

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

    func testBuiltInPresetsAreNamedWithoutDigitsAndScaleToExtreme() {
        let titles = ProcessSettingsPreset.builtIn.map(\.title)
        XCTAssertEqual(titles, ["Default", "Fast", "Heavy", "Max", "Extreme"])
        for title in titles {
            XCTAssertFalse(title.contains(where: \.isNumber), "title should not contain digits: \(title)")
        }

        XCTAssertEqual(ProcessSettingsPreset.defaultPresetID, "builtin.default")

        let byID = Dictionary(uniqueKeysWithValues: ProcessSettingsPreset.builtIn.map { ($0.id, $0) })
        XCTAssertEqual(byID["builtin.default"]?.snapshot.mdxcSegmentSize, SeparationSettings.defaultMDXCSegmentSize)
        XCTAssertEqual(byID["builtin.fast"]?.snapshot.mdxcSegmentSize, 512)
        XCTAssertEqual(byID["builtin.heavy"]?.snapshot.mdxcSegmentSize, 1024)
        XCTAssertEqual(byID["builtin.max"]?.snapshot.mdxcSegmentSize, 2048)
        XCTAssertEqual(byID["builtin.extreme"]?.snapshot.mdxcSegmentSize, 4096)
        XCTAssertTrue(byID["builtin.extreme"]?.snapshot.mdxcOverrideModelSegmentSize == true)
        XCTAssertNil(byID["metal.fast"])
        XCTAssertNil(byID["metal.max"])
    }

    func testPreferredVisiblePresetUsesListOrderLikeModels() {
        let presets = ProcessSettingsPreset.builtIn
        // All visible → first in list (Default).
        XCTAssertEqual(
            ProcessSettingsPreset.preferredVisiblePresetID(in: presets, isVisible: { _ in true }),
            "builtin.default"
        )

        // Default + Fast hidden → first open eye is Heavy.
        let hidden: Set<String> = ["builtin.default", "builtin.fast"]
        XCTAssertEqual(
            ProcessSettingsPreset.preferredVisiblePresetID(
                in: presets,
                isVisible: { !hidden.contains($0) }
            ),
            "builtin.heavy"
        )

        // Excluding current Heavy while it is the only… next is Max.
        let onlyAfterHeavy = ProcessSettingsPreset.preferredVisiblePresetID(
            in: presets,
            isVisible: { !["builtin.default", "builtin.fast"].contains($0) },
            excluding: "builtin.heavy"
        )
        XCTAssertEqual(onlyAfterHeavy, "builtin.max")
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

    // MARK: - D1: process preset → Custom when dirty

    private func heavyPreset() -> ProcessSettingsPreset {
        ProcessSettingsPreset.builtIn.first { $0.id == "builtin.heavy" }!
    }
    func testDefaultPresetTitleIsCleanForUntouchedSettings() {
        let defaultPreset = ProcessSettingsPreset.builtIn.first { $0.id == ProcessSettingsPreset.defaultPresetID }!
        let settings = SeparationSettings()

        XCTAssertFalse(defaultPreset.isDirty(settings: settings))
        XCTAssertEqual(
            ProcessSettingsPreset.displayTitle(
                for: defaultPreset.id,
                in: ProcessSettingsPreset.builtIn,
                settings: settings
            ),
            "Default"
        )
    }

    func testDefaultPresetSnapshotRoundTripIsClean() {
        let defaultPreset = ProcessSettingsPreset.builtIn.first { $0.id == ProcessSettingsPreset.defaultPresetID }!
        var settings = SeparationSettings()

        defaultPreset.snapshot.apply(to: &settings)

        XCTAssertFalse(defaultPreset.isDirty(settings: settings))
    }

    func testModelSelectionChangesDoNotDirtyDefaultProcessPreset() {
        let defaultPreset = ProcessSettingsPreset.builtIn.first { $0.id == ProcessSettingsPreset.defaultPresetID }!
        var settings = SeparationSettings()
        defaultPreset.snapshot.apply(to: &settings)

        settings.presetID = "viperx_vocal"
        settings.modelOverride = "custom.ckpt"

        XCTAssertFalse(defaultPreset.isDirty(settings: settings))
        XCTAssertEqual(
            ProcessSettingsPreset.displayTitle(
                for: defaultPreset.id,
                in: ProcessSettingsPreset.builtIn,
                settings: settings
            ),
            "Default"
        )
    }


    func testDisplayTitleShowsPresetTitleWhenSettingsMatchSnapshot() {
        let heavy = heavyPreset()
        var settings = SeparationSettings()
        heavy.snapshot.apply(to: &settings)

        XCTAssertFalse(heavy.isDirty(settings: settings))
        XCTAssertEqual(
            ProcessSettingsPreset.displayTitle(for: heavy.id, in: ProcessSettingsPreset.builtIn, settings: settings),
            "Heavy"
        )
    }

    func testDisplayTitleShowsCustomWhenSegmentSizeDiverges() {
        let heavy = heavyPreset()
        var settings = SeparationSettings()
        heavy.snapshot.apply(to: &settings)
        settings.mdxcSegmentSize = 2048

        XCTAssertTrue(heavy.isDirty(settings: settings))
        XCTAssertEqual(
            ProcessSettingsPreset.displayTitle(for: heavy.id, in: ProcessSettingsPreset.builtIn, settings: settings),
            "Custom"
        )
    }

    func testDisplayTitleShowsCustomForBatchChunkAndOverlapDivergence() {
        let heavy = heavyPreset()

        var batchSettings = SeparationSettings()
        heavy.snapshot.apply(to: &batchSettings)
        batchSettings.mdxcBatchSize = 4
        XCTAssertTrue(heavy.isDirty(settings: batchSettings))
        XCTAssertEqual(
            ProcessSettingsPreset.displayTitle(for: heavy.id, in: ProcessSettingsPreset.builtIn, settings: batchSettings),
            "Custom"
        )

        var chunkSettings = SeparationSettings()
        heavy.snapshot.apply(to: &chunkSettings)
        chunkSettings.chunkDuration = 99
        XCTAssertTrue(heavy.isDirty(settings: chunkSettings))

        var overlapSettings = SeparationSettings()
        heavy.snapshot.apply(to: &overlapSettings)
        overlapSettings.mdxcOverlap = 1
        XCTAssertTrue(heavy.isDirty(settings: overlapSettings))
    }

    func testReapplyingPresetReturnsToCleanDisplayTitle() {
        let heavy = heavyPreset()
        var settings = SeparationSettings()
        heavy.snapshot.apply(to: &settings)
        settings.mdxcSegmentSize = 2048
        XCTAssertEqual(
            ProcessSettingsPreset.displayTitle(for: heavy.id, in: ProcessSettingsPreset.builtIn, settings: settings),
            "Custom"
        )

        // Mirrors the applyProcessPreset path used by the UI.
        heavy.snapshot.apply(to: &settings)
        XCTAssertFalse(heavy.isDirty(settings: settings))
        XCTAssertEqual(
            ProcessSettingsPreset.displayTitle(for: heavy.id, in: ProcessSettingsPreset.builtIn, settings: settings),
            "Heavy"
        )
    }
}
