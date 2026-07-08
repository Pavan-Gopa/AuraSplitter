import XCTest
@testable import KirtanSplitterApp

final class ModelPresetMenuStateTests: XCTestCase {
    func testMenuStateMarksDownloadedPresetAndShowsUsageCount() {
        let preset = SeparationPreset(
            id: "kirtan_pro",
            title: "Kirtan Pro",
            modelFilename: "BS-Roformer-SW.ckpt",
            summary: "Six stem split",
            expectedStems: ["vocals"],
            usageCount: 7
        )
        let model = SeparatorModel(
            filename: "BS-Roformer-SW.ckpt",
            name: "Kirtan Pro",
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
            title: "Kirtan Clean Split",
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
                    displayName: "Kirtan Clean Split",
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
}
