import XCTest
@testable import KirtanSplitterApp

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

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
