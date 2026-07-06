import XCTest
@testable import KirtanSplitterApp

final class SpectrogramImageRendererTests: XCTestCase {
    func testRendererCreatesTextureWithSpectrogramDimensions() {
        let spectrogram = SpectrogramData(
            columns: 3,
            bins: 2,
            values: [
                0.0, 0.2,
                0.5, 0.7,
                0.9, 1.0,
            ]
        )

        let image = SpectrogramImageRenderer.makeImage(from: spectrogram)

        XCTAssertEqual(image?.width, 3)
        XCTAssertEqual(image?.height, 2)
    }
}
