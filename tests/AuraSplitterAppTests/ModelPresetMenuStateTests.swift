import XCTest
@testable import AuraSplitterApp

final class ModelPresetMenuStateTests: XCTestCase {
    func testMenuStateMarksDownloadedPresetAndShowsUsageCount() {
        let preset = SeparationPreset(
            id: "kirtan_pro",
            title: "Aura Pro",
            modelFilename: "BS-Roformer-SW.ckpt",
            summary: "Six stem split",
            expectedStems: ["vocals"],
            usageCount: 7
        )
        let model = SeparatorModel(
            filename: "BS-Roformer-SW.ckpt",
            name: "Aura Pro",
            type: "MDXC",
            stems: ["vocals"],
            sdr: [:],
            isDownloaded: true
        )

        let state = ModelPresetMenuState(preset: preset, models: [model], modelCache: nil)

        XCTAssertTrue(state.isLocal)
        XCTAssertEqual(state.usageCount, 7)
        XCTAssertEqual(state.usageLabel, "x7")
        XCTAssertEqual(state.helpText, "Cached locally - used 7 times")
    }

    func testMenuStateCanReadLocalStatusFromModelCacheGroup() {
        let preset = SeparationPreset(
            id: "vocal_clean",
            title: "Aura Clean Split",
            modelFilename: "model_bs_roformer_ep_317_sdr_12.9755.ckpt",
            summary: "Vocal split",
            expectedStems: ["vocals"],
            usageCount: 0
        )
        let cache = ModelCache(
            modelDir: "/tmp/models",
            totalBytes: 1024,
            items: [],
            groups: [
                ModelCacheGroup(
                    id: "model_bs_roformer_ep_317_sdr_12.9755",
                    displayName: "Aura Clean Split",
                    technicalName: "model_bs_roformer_ep_317_sdr_12.9755.ckpt",
                    architecture: "BS-RoFormer",
                    backend: "MLX",
                    license: nil,
                    sourceURL: nil,
                    summary: nil,
                    localState: "installed",
                    converted: true,
                    hasSource: false,
                    sourceRemoved: true,
                    canDeleteSource: false,
                    totalBytes: 1024,
                    sourceBytes: 0,
                    convertedBytes: 1024,
                    configBytes: 0,
                    sourcePath: nil,
                    convertedPath: "/tmp/models/model_bs_roformer_ep_317_sdr_12.9755.safetensors",
                    configPath: nil,
                    usageCount: 3,
                    files: []
                )
            ]
        )

        let state = ModelPresetMenuState(preset: preset, models: [], modelCache: cache)

        XCTAssertTrue(state.isLocal)
        XCTAssertEqual(state.usageCount, 3)
        XCTAssertEqual(state.usageLabel, "x3")
    }

    func testMenuStateDoesNotMarkNotDownloadedCacheGroupAsLocal() {
        let preset = SeparationPreset(
            id: "demucs_onnx_stems",
            title: "Aura Stems Pro",
            modelFilename: "htdemucs_ft.onnx",
            summary: "ONNX stems",
            expectedStems: ["vocals"],
            usageCount: 0
        )
        let model = SeparatorModel(
            filename: "htdemucs_ft.onnx",
            name: "Aura Stems Pro",
            type: "ONNX/CoreML",
            stems: ["vocals"],
            sdr: [:],
            isDownloaded: false
        )
        let cache = ModelCache(
            modelDir: "/tmp/models",
            totalBytes: 0,
            items: [],
            groups: [
                ModelCacheGroup(
                    id: "htdemucs_ft",
                    displayName: "Aura Stems Pro",
                    technicalName: "HT-Demucs FT ONNX",
                    architecture: "HT-Demucs",
                    backend: "ONNX/CoreML",
                    license: nil,
                    sourceURL: nil,
                    summary: nil,
                    localState: "not_downloaded",
                    converted: false,
                    hasSource: false,
                    sourceRemoved: false,
                    canDeleteSource: false,
                    totalBytes: 0,
                    sourceBytes: 0,
                    convertedBytes: 0,
                    configBytes: 0,
                    sourcePath: nil,
                    convertedPath: nil,
                    configPath: nil,
                    usageCount: 0,
                    files: []
                )
            ]
        )

        let state = ModelPresetMenuState(preset: preset, models: [model], modelCache: cache)

        XCTAssertFalse(state.isLocal)
        XCTAssertNil(state.usageLabel)
        XCTAssertEqual(state.helpText, "Downloads on first use")
    }

    func testMenuStateDoesNotTreatRemovedSourceWithoutConvertedWeightsAsLocal() {
        let preset = SeparationPreset(
            id: "broken",
            title: "Broken Local",
            modelFilename: "broken.ckpt",
            summary: "Missing converted weights",
            expectedStems: ["vocals"],
            usageCount: 0
        )
        let cache = ModelCache(
            modelDir: "/tmp/models",
            totalBytes: 0,
            items: [],
            groups: [
                ModelCacheGroup(
                    id: "broken",
                    displayName: "Broken Local",
                    technicalName: "broken.ckpt",
                    architecture: "BS-RoFormer",
                    backend: "MLX",
                    license: nil,
                    sourceURL: nil,
                    summary: nil,
                    localState: "source_removed",
                    converted: false,
                    hasSource: false,
                    sourceRemoved: true,
                    canDeleteSource: false,
                    totalBytes: 0,
                    sourceBytes: 0,
                    convertedBytes: 0,
                    configBytes: 0,
                    sourcePath: nil,
                    convertedPath: nil,
                    configPath: nil,
                    usageCount: 0,
                    files: []
                )
            ]
        )

        let state = ModelPresetMenuState(preset: preset, models: [], modelCache: cache)

        XCTAssertFalse(state.isLocal)
    }
}
