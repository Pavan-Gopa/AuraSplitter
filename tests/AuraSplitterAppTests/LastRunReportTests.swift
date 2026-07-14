import XCTest
@testable import AuraSplitterApp

final class LastRunReportTests: XCTestCase {
    func testLastRunReportIncludesTimestampsSettingsMetricsAndOutputFiles() throws {
        let summary = try JSONDecoder().decode(
            SeparationSummary.self,
            from: Data(
                """
                {
                  "model": "BS-Roformer-SW.ckpt",
                  "preset": "kirtan_pro",
                  "processPresetTitle": "Heavy 1024",
                  "startedAt": 1783510200.0,
                  "completedAt": 1783510265.5,
                  "elapsedSeconds": 65.5,
                  "modelHot": false,
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
                  },
                  "postRunStats": {
                    "modelHot": false,
                    "processPresetTitle": "Heavy 1024",
                    "sourceDurationSeconds": 2683.3,
                    "elapsedSeconds": 65.5,
                    "realtimeFactor": 40.966,
                    "chunkDurationSeconds": 30,
                    "chunkLabel": "30s",
                    "estimatedChunks": 90,
                    "segmentSize": 1024,
                    "overlap": 10,
                    "batchSize": 2,
                    "batchExplicit": true,
                    "speedMode": "latency_safe_v3",
                    "experimentalFlagsEnabled": 0,
                    "experimentalFlags": []
                  }
                }
                """.utf8
            )
        )

        let report = LastRunReport(summary: summary)

        XCTAssertTrue(report.overviewRows.map(\.0).contains("process"))
        XCTAssertEqual(report.settingRows.first?.0, "chunk")
        XCTAssertEqual(report.metricRows.map(\.0), ["inference", "write"])
        XCTAssertEqual(report.fileRows.map(\.0), ["Vocals"])
        XCTAssertEqual(report.fileRows.map(\.1), ["song_(Vocals).wav - 42 bytes"])
        XCTAssertTrue(report.postRunStatRows.contains(where: { $0.0 == "est. chunks" && $0.1 == "90" }))
        XCTAssertTrue(report.postRunStatRows.contains(where: { $0.0 == "model cache" && $0.1.contains("cold") }))
        XCTAssertTrue(report.statusLineSummary.contains("chunk 30s"))
        XCTAssertTrue(report.statusLineSummary.contains("batch 2"))
        XCTAssertEqual(
            LastRunReport.formattedRunDate(1_783_510_200, timeZone: TimeZone(secondsFromGMT: 0)!),
            "2026-07-08 11:30:00"
        )
    }
}
