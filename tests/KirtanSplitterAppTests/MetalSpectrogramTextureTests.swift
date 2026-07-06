import XCTest
@testable import KirtanSplitterApp

final class MetalSpectrogramTextureTests: XCTestCase {
    func testTexturePayloadKeepsDimensionsAndColumnMajorValuesInRowMajorFloatOrder() {
        let spectrogram = SpectrogramData(
            columns: 3,
            bins: 2,
            values: [
                0.1, 0.2,
                0.3, 0.4,
                0.5, 0.6,
            ]
        )

        let payload = MetalSpectrogramTexturePayload(spectrogram: spectrogram)

        XCTAssertEqual(payload?.width, 3)
        XCTAssertEqual(payload?.height, 2)
        let expected: [Float] = [
            0.1, 0.3, 0.5,
            0.2, 0.4, 0.6,
        ]
        XCTAssertEqual(payload?.floats.count, expected.count)
        for (actual, expected) in zip(payload?.floats ?? [], expected) {
            XCTAssertEqual(actual, expected, accuracy: 0.0001)
        }
    }

    func testTexturePayloadRejectsIncompleteSpectrogramValues() {
        let spectrogram = SpectrogramData(columns: 2, bins: 2, values: [0.1, 0.2, 0.3])

        XCTAssertNil(MetalSpectrogramTexturePayload(spectrogram: spectrogram))
    }
}
