import XCTest
@testable import KirtanSplitterApp

final class AudioPreviewViewportTests: XCTestCase {
    func testZoomInAroundCursorNarrowsRangeAndKeepsAnchorStable() {
        var viewport = AudioPreviewViewport()

        viewport.zoom(deltaY: 10, anchorFraction: 0.25)

        XCTAssertLessThan(viewport.span, 1.0)
        XCTAssertEqual(viewport.start, 0.25 - viewport.span * 0.25, accuracy: 0.001)
    }

    func testZoomOutReturnsToFullRange() {
        var viewport = AudioPreviewViewport()

        viewport.zoom(deltaY: 10, anchorFraction: 0.5)
        viewport.zoom(deltaY: -1_000, anchorFraction: 0.5)

        XCTAssertEqual(viewport.start, 0, accuracy: 0.001)
        XCTAssertEqual(viewport.end, 1, accuracy: 0.001)
    }

    func testPanMovesVisibleRangeAndClampsToBounds() {
        var viewport = AudioPreviewViewport()
        viewport.zoom(deltaY: 10, anchorFraction: 0.5)
        let initialStart = viewport.start

        viewport.pan(deltaX: -200, canvasWidth: 1_000)

        XCTAssertGreaterThan(viewport.start, initialStart)
        viewport.pan(deltaX: 20_000, canvasWidth: 1_000)
        XCTAssertEqual(viewport.start, 0, accuracy: 0.001)
    }
}
