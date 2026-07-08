import XCTest
@testable import KirtanSplitterApp

final class ModelStoragePathsTests: XCTestCase {
    func testDefaultModelDirectoryLivesInUserVisibleSoundFolder() {
        let path = ModelStoragePaths.defaultModelDirectory(homeDirectory: "/Users/pavan")

        XCTAssertEqual(path, "/Users/pavan/AI_LOCAL_MODELS/Sound/KirtanSplitter")
    }

    func testLegacyModelDirectoryPointsToApplicationSupportCache() {
        let path = ModelStoragePaths.legacyApplicationSupportModelDirectory(homeDirectory: "/Users/pavan")

        XCTAssertEqual(path, "/Users/pavan/Library/Application Support/KirtanSplitter/models")
    }
}
