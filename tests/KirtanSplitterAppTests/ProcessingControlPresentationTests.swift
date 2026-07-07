import XCTest
@testable import KirtanSplitterApp

final class ProcessingControlPresentationTests: XCTestCase {
    func testIdleStateShowsStartActionWhenBackendAndSourcesAreReady() {
        let presentation = ProcessingControlPresentation(isProcessing: false, isCancelling: false)

        XCTAssertEqual(presentation.primaryTitle, "Start")
        XCTAssertEqual(presentation.primarySystemImage, "play.fill")
        XCTAssertFalse(presentation.showsCancelAction)
        XCTAssertFalse(presentation.isStartDisabled(isReady: true, hasSelectedSources: true))
    }

    func testRunningStateShowsCancelActionAndDisablesStart() {
        let presentation = ProcessingControlPresentation(isProcessing: true, isCancelling: false)

        XCTAssertEqual(presentation.primaryTitle, "Separating")
        XCTAssertTrue(presentation.showsCancelAction)
        XCTAssertTrue(presentation.isStartDisabled(isReady: true, hasSelectedSources: true))
    }

    func testCancellingStateKeepsControlsBlockedUntilBackendRestarts() {
        let presentation = ProcessingControlPresentation(isProcessing: false, isCancelling: true)

        XCTAssertEqual(presentation.primaryTitle, "Cancelling")
        XCTAssertFalse(presentation.showsCancelAction)
        XCTAssertTrue(presentation.isStartDisabled(isReady: true, hasSelectedSources: true))
    }
}
