import XCTest
@testable import AuraSplitterApp

final class ModelStoragePathsTests: XCTestCase {
    func testDefaultModelDirectoryLivesInUserVisibleSoundFolder() {
        let path = ModelStoragePaths.defaultModelDirectory(homeDirectory: "/Users/pavan")

        XCTAssertEqual(path, "/Users/pavan/AI_LOCAL_MODELS/Sound/AuraSplitter")
    }

    func testLegacySoundModelDirectoryKeepsPreRebrandPath() {
        let path = ModelStoragePaths.legacySoundModelDirectory(homeDirectory: "/Users/pavan")

        XCTAssertEqual(path, "/Users/pavan/AI_LOCAL_MODELS/Sound/KirtanSplitter")
    }

    func testLegacyModelDirectoryPointsToApplicationSupportCache() {
        let path = ModelStoragePaths.legacyApplicationSupportModelDirectory(homeDirectory: "/Users/pavan")

        XCTAssertEqual(path, "/Users/pavan/Library/Application Support/KirtanSplitter/models")
    }

    func testDefaultLogFileUsesAuraApplicationSupport() {
        let path = ModelStoragePaths.defaultLogFile(homeDirectory: "/Users/pavan")

        XCTAssertEqual(
            path,
            "/Users/pavan/Library/Application Support/AuraSplitter/logs/backend.log"
        )
    }
}
