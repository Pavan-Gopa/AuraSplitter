import XCTest
@testable import AuraSplitterApp

final class ProcessingControlPresentationTests: XCTestCase {
    func testIdleStateShowsStartActionWhenBackendAndSourcesAreReady() {
        let presentation = ProcessingControlPresentation(isReady: true, isProcessing: false, isCancelling: false)

        XCTAssertEqual(presentation.primaryTitle, "Start")
        XCTAssertEqual(presentation.primarySystemImage, "play.fill")
        XCTAssertFalse(presentation.isDestructive)
        XCTAssertFalse(presentation.isPrimaryDisabled(hasSelectedSources: true))
    }

    func testRunningStateTurnsPrimaryActionIntoCancelWithoutAddingASecondButton() {
        let presentation = ProcessingControlPresentation(isReady: true, isProcessing: true, isCancelling: false)

        XCTAssertEqual(presentation.primaryTitle, "Cancel")
        XCTAssertEqual(presentation.primarySystemImage, "xmark.circle.fill")
        XCTAssertTrue(presentation.isDestructive)
        XCTAssertFalse(presentation.usesSeparateCancelButton)
        XCTAssertFalse(presentation.isPrimaryDisabled(hasSelectedSources: true))
    }

    func testCancellingStateKeepsControlsBlockedUntilBackendRestarts() {
        let presentation = ProcessingControlPresentation(isReady: true, isProcessing: false, isCancelling: true)

        XCTAssertEqual(presentation.primaryTitle, "Cancelling")
        XCTAssertTrue(presentation.isPrimaryDisabled(hasSelectedSources: true))
    }

    func testBackendUnavailableStateOffersRestartAction() {
        let presentation = ProcessingControlPresentation(isReady: false, isProcessing: false, isCancelling: false)

        XCTAssertEqual(presentation.primaryTitle, "Restart")
        XCTAssertEqual(presentation.primarySystemImage, "arrow.clockwise")
        XCTAssertFalse(presentation.isPrimaryDisabled(hasSelectedSources: false))
    }
}
