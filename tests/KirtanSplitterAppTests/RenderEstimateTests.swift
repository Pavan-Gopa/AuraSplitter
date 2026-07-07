import XCTest
@testable import KirtanSplitterApp

final class RenderEstimateTests: XCTestCase {
    func testRenderEstimateDecodesCalibratedBackendResponse() throws {
        let data = Data(
            """
            {
              "status": "calibrated",
              "reason": null,
              "modelFilename": "BS-Roformer-SW.ckpt",
              "processPresetID": "builtin.heavy",
              "estimatedSeconds": 1452.4,
              "audioDurationSeconds": 2683.0,
              "sampleCount": 3,
              "baselineGpuCoreCount": 10,
              "targetGpuCoreCount": 20,
              "secondsPerAudioSecond": 0.541334
            }
            """.utf8
        )

        let estimate = try JSONDecoder().decode(RenderEstimate.self, from: data)

        XCTAssertEqual(estimate.status, "calibrated")
        XCTAssertEqual(estimate.estimatedSeconds, 1452.4)
        XCTAssertEqual(estimate.displayText, "Est. 24m 12s")
        XCTAssertEqual(estimate.detailText, "3 samples - 10 -> 20 GPU cores")
    }

    func testRenderEstimateShowsPendingUntilCalibrationExists() throws {
        let data = Data(
            """
            {
              "status": "unavailable",
              "reason": "no_calibration",
              "modelFilename": "BS-Roformer-SW.ckpt",
              "processPresetID": "builtin.fast",
              "estimatedSeconds": null,
              "audioDurationSeconds": 120.0,
              "sampleCount": 0,
              "baselineGpuCoreCount": null,
              "targetGpuCoreCount": null,
              "secondsPerAudioSecond": null
            }
            """.utf8
        )

        let estimate = try JSONDecoder().decode(RenderEstimate.self, from: data)

        XCTAssertEqual(estimate.displayText, "Estimate pending")
        XCTAssertEqual(estimate.detailText, "Run once to calibrate")
    }
}
