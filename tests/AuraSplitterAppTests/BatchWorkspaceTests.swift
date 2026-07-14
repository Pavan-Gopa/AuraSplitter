import XCTest
@testable import AuraSplitterApp

final class BatchWorkspaceTests: XCTestCase {
    func testAudioFilesInFolderReturnsOnlyFirstLevelAudioFilesSortedByName() throws {
        let folder = try makeTemporaryDirectory()
        try Data().write(to: folder.appendingPathComponent("b.flac"))
        try Data().write(to: folder.appendingPathComponent("a.WAV"))
        try Data().write(to: folder.appendingPathComponent("notes.txt"))
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("nested"),
            withIntermediateDirectories: true
        )
        try Data().write(to: folder.appendingPathComponent("nested/inside.wav"))

        let files = BatchWorkspace.audioFiles(in: folder)

        XCTAssertEqual(files.map(\.lastPathComponent), ["a.WAV", "b.flac"])
    }

    func testMakeSourcesSelectsEveryAudioFileWithDefaultPreset() throws {
        let folder = try makeTemporaryDirectory()
        let first = folder.appendingPathComponent("one.wav")
        let second = folder.appendingPathComponent("two.mp3")

        let sources = BatchWorkspace.makeSources(from: [second, first], defaultPresetID: "vocal_clean")

        XCTAssertEqual(sources.map(\.url), [first, second])
        XCTAssertEqual(sources.map(\.presetID), ["vocal_clean", "vocal_clean"])
        XCTAssertEqual(sources.map(\.isSelectedForProcessing), [true, true])
    }

    func testDeleteStemRemovesFileAndResultGroupEntry() throws {
        let folder = try makeTemporaryDirectory()
        let stemURL = folder.appendingPathComponent("mix_(Vocals).wav")
        try Data("audio".utf8).write(to: stemURL)

        let source = folder.appendingPathComponent("mix.wav")
        var groups = [
            BatchResultGroup(
                sourceURL: source,
                summary: nil,
                files: [
                    StemFile(stem: "vocals", path: stemURL.path, sizeBytes: 5),
                    StemFile(stem: "instrumental", path: folder.appendingPathComponent("mix_(Instrumental).wav").path, sizeBytes: 6),
                ]
            )
        ]

        try BatchWorkspace.deleteStem(at: stemURL.path, from: &groups)

        XCTAssertFalse(FileManager.default.fileExists(atPath: stemURL.path))
        XCTAssertEqual(groups[0].files.map(\.stem), ["instrumental"])
    }

    func testEffectivePresetForSingleSourceUsesGlobalPreset() throws {
        let folder = try makeTemporaryDirectory()
        let source = BatchSourceItem(
            url: folder.appendingPathComponent("one.wav"),
            isSelectedForProcessing: true,
            presetID: "stale_per_file"
        )

        let presetID = BatchWorkspace.effectivePresetID(
            for: source,
            sourceCount: 1,
            globalPresetID: "global_current"
        )

        XCTAssertEqual(presetID, "global_current")
    }

    func testEffectivePresetForBatchUsesPerSourcePreset() throws {
        let folder = try makeTemporaryDirectory()
        let source = BatchSourceItem(
            url: folder.appendingPathComponent("one.wav"),
            isSelectedForProcessing: true,
            presetID: "per_file"
        )

        let presetID = BatchWorkspace.effectivePresetID(
            for: source,
            sourceCount: 3,
            globalPresetID: "global_current"
        )

        XCTAssertEqual(presetID, "per_file")
    }

    func testDiscoverStemFilesLoadsExistingExperimentsFromStemsFolder() throws {
        let root = try makeTemporaryDirectory()
        let source = root.appendingPathComponent("02BACK.wav")
        try Data("src".utf8).write(to: source)
        let stemsDir = root.appendingPathComponent("02BACK_stems")
        try FileManager.default.createDirectory(at: stemsDir, withIntermediateDirectories: true)

        let v1 = stemsDir.appendingPathComponent("02BACK_(vocals)_Elite_Heavy.wav")
        let v2 = stemsDir.appendingPathComponent("02BACK_(vocals 2)_Elite_Max.wav")
        let other = stemsDir.appendingPathComponent("02BACK_(other)_Elite_Heavy.wav")
        let sidecar = stemsDir.appendingPathComponent("02BACK_(vocals)_Elite_Heavy.kirtan-run.json")
        try Data("a".utf8).write(to: v1)
        try Data("b".utf8).write(to: v2)
        try Data("c".utf8).write(to: other)
        try Data(
            """
            {"formatVersion":1,"processPresetTitle":"Heavy","chunkLabel":"90s","segmentSize":1024,"batchSize":2}
            """.utf8
        ).write(to: sidecar)

        let files = BatchWorkspace.discoverStemFiles(in: stemsDir, relatedTo: source)

        XCTAssertEqual(files.count, 3)
        XCTAssertTrue(files.contains { $0.stem == "vocals" })
        XCTAssertTrue(files.contains { $0.stem == "vocals_2" })
        XCTAssertTrue(files.contains { $0.stem == "other" })
        let firstVocals = files.first { $0.stem == "vocals" }
        XCTAssertEqual(firstVocals?.runInfo?.processPresetTitle, "Heavy")
        XCTAssertEqual(firstVocals?.runInfo?.chunkLabel, "90s")
        XCTAssertEqual(BatchWorkspace.defaultStemsDirectory(for: source).path, stemsDir.path)
    }

    func testStemFileDisplayNameParsingWithModelAndPresetSuffix() throws {
        let vocalsNoSuffix = StemFile(stem: "vocals", path: "/path/to/MySong_(vocals).wav", sizeBytes: 100)
        XCTAssertEqual(vocalsNoSuffix.displayName, "Vocals")

        let vocalsWithModel = StemFile(stem: "vocals", path: "/path/to/MySong_(vocals)_Aura Pro.wav", sizeBytes: 100)
        XCTAssertEqual(vocalsWithModel.displayName, "Vocals • Aura Pro")

        let vocalsWithModelAndPreset = StemFile(stem: "vocals", path: "/path/to/MySong_(vocals)_Aura Pro_Heavy.wav", sizeBytes: 100)
        XCTAssertEqual(vocalsWithModelAndPreset.displayName, "Vocals • Aura Pro • Heavy")

        let vocalsVersion2 = StemFile(stem: "vocals_2", path: "/path/to/MySong_(vocals 2)_Aura Pro_Heavy.wav", sizeBytes: 100)
        XCTAssertEqual(vocalsVersion2.displayName, "Vocals 2 • Aura Pro • Heavy")

        let leadVocalsWithSpaces = StemFile(stem: "lead_vocals", path: "/path/to/MySong_(lead vocals)_Aura Clean Split_Fast.wav", sizeBytes: 100)
        XCTAssertEqual(leadVocalsWithSpaces.displayName, "Lead Vocals • Aura Clean Split • Fast")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
