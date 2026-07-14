import XCTest
@testable import AuraSplitterApp

final class AudioPreviewAxisScaleTests: XCTestCase {
    func testDecibelAxisUsesDenseRxStyleMajorLabels() {
        let labels = AudioPreviewAxisScale.decibelTicks
            .filter(\.isMajor)
            .map(\.label)

        XCTAssertEqual(labels, ["0", "-1", "-2", "-3", "-4", "-5", "-6", "-8", "-10", "-12", "-20", "-24"])
    }

    func testDecibelAxisIncludesMinorTicksBetweenMajorLabels() {
        let minorValues = AudioPreviewAxisScale.decibelTicks
            .filter { !$0.isMajor }
            .map(\.db)

        XCTAssertTrue(minorValues.contains(-0.5))
        XCTAssertTrue(minorValues.contains(-7))
        XCTAssertTrue(minorValues.contains(-18))
    }
}
