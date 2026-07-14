import Metal
import XCTest
@testable import AuraSplitterApp

final class MetalSpectrogramShaderTests: XCTestCase {
    func testSpectrogramShaderCompilesOnDefaultMetalDevice() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is not available in this environment.")
        }

        XCTAssertNoThrow(try device.makeLibrary(source: MetalSpectrogramShader.source, options: nil))
    }
}
