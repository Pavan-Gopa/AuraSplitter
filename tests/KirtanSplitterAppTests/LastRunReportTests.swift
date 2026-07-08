import XCTest
@testable import KirtanSplitterApp

final class LastRunReportTests: XCTestCase {
    func testLastRunReportIncludesTimestampsSettingsMetricsAndOutputFiles() throws {
        let summary = try JSONDecoder().decode(
            SeparationSummary.self,
            from: Data(
                """
                {
                  "model": "BS-Roformer-SW.ckpt",
                  "preset": "kirtan_pro",
                  "startedAt": 1783510200.0,
                  "completedAt": 1783510265.5,
                  "elapsedSeconds": 65.5,
                  "files": [
                    {"stem": "vocals", "path": "/tmp/song_(Vocals).wav", "sizeBytes": 42}
                  ],
                  "metrics": {"inference_s": 40.125, "write_s": 3.5},
                  "settings": {
                    "chunkDuration": 30,
                    "mdxcSegmentSize": 1024,
                    "mdxcOverlap": 10,
                    "mdxcBatchSize": 2,
                    "mdxcOverrideModelSegmentSize": true,
                    "speedMode": "latency_safe_v3"
                  }
                }
                """.utf8
            )
        )

        let report = LastRunReport(summary: summary)

        XCTAssertEqual(report.overviewRows.map(\.0), ["model", "preset", "started", "completed", "elapsed", "outputs", "output size"])
        XCTAssertEqual(report.settingRows.first?.0, "chunk")
        XCTAssertEqual(report.metricRows.map(\.0), ["inference", "write"])
        XCTAssertEqual(report.fileRows.map(\.0), ["Vocals"])
        XCTAssertEqual(report.fileRows.map(\.1), ["song_(Vocals).wav - 42 bytes"])
        XCTAssertEqual(
            LastRunReport.formattedRunDate(1_783_510_200, timeZone: TimeZone(secondsFromGMT: 0)!),
            "2026-07-08 11:30:00"
        )
    }
}
