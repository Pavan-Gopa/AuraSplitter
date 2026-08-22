import XCTest
@testable import AuraSplitterApp

final class AutomationModelsTests: XCTestCase {
    func testMergeOverlappingZones() {
        let a = AutomationTimeRange(start: 0, end: 10)
        let b = AutomationTimeRange(start: 8, end: 20)
        let c = AutomationTimeRange(start: 30, end: 40)
        let merged = AutomationTimeRange.merge([a, b, c])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].start, 0, accuracy: 0.001)
        XCTAssertEqual(merged[0].end, 20, accuracy: 0.001)
        XCTAssertEqual(merged[1].start, 30, accuracy: 0.001)
    }

    func testKeptSegmentsSubtractExclusions() {
        let zones = [
            AutomationTimeRange(start: 10, end: 20),
            AutomationTimeRange(start: 40, end: 50),
        ]
        let kept = AutomationTimeRange.keptSegments(duration: 60, excluding: zones)
        XCTAssertEqual(kept.count, 3)
        XCTAssertEqual(kept[0].start, 0, accuracy: 0.001)
        XCTAssertEqual(kept[0].end, 10, accuracy: 0.001)
        XCTAssertEqual(kept[1].start, 20, accuracy: 0.001)
        XCTAssertEqual(kept[1].end, 40, accuracy: 0.001)
        XCTAssertEqual(kept[2].start, 50, accuracy: 0.001)
        XCTAssertEqual(kept[2].end, 60, accuracy: 0.001)
    }

    func testFinalFileNaming() {
        XCTAssertEqual(
            AutomationNaming.finalFileName(shortOutputName: "Main Vocal", stem: "vocals", stemCount: 1),
            "Main Vocal.wav"
        )
        XCTAssertEqual(
            AutomationNaming.finalFileName(shortOutputName: "Track", stem: "drums", stemCount: 2),
            "Track_drums.wav"
        )
    }

    func testIntermediateDisplayName() {
        XCTAssertEqual(
            AutomationNaming.intermediateDisplayName(shortOutputName: "MAIN_V", stem: "vocals"),
            "MAIN_V(Vocal)"
        )
        XCTAssertEqual(
            AutomationNaming.intermediateDisplayName(shortOutputName: "MAIN_V", stem: "drums"),
            "MAIN_V(Drum)"
        )
        XCTAssertEqual(
            AutomationNaming.intermediateDisplayName(shortOutputName: "BACK_V", stem: "lead"),
            // stemRoleShortLabel maps lead → Lead (matches engine's canonical roles).
            "BACK_V(Lead)"
        )
        XCTAssertEqual(
            AutomationNaming.intermediateDisplayName(shortOutputName: "X", stem: "kick"),
            "X(Kick)"
        )
    }

    func testBuildStep2TracksFromStep1Stems() {
        var track = AutomationTrackPlan(sourceURL: URL(fileURLWithPath: "/tmp/01MAIN_V.WAV"))
        track.shortOutputName = "MAIN_V"
        track.stemSelections = [
            "model_a": ["vocals", "drums"],
        ]
        let step2 = AutomationJob.buildStep2Tracks(from: [track])
        XCTAssertEqual(step2.count, 2)
        let names = Set(step2.map(\.displayName))
        XCTAssertTrue(names.contains("MAIN_V(Drum)"))
        XCTAssertTrue(names.contains("MAIN_V(Vocal)"))
        XCTAssertEqual(step2.map(\.parentTrackID), [track.id, track.id])
    }

    func testDefaultReadyMixFolder() {
        let source = URL(fileURLWithPath: "/tmp/Session")
        XCTAssertEqual(
            AutomationJob.defaultOutputFolder(for: source).path,
            "/tmp/Session/Ready MIX"
        )
        XCTAssertEqual(
            AutomationJob.intermediateFolder(for: URL(fileURLWithPath: "/tmp/Session/Ready MIX")).path,
            "/tmp/Session/Ready MIX/_AutomationStep1"
        )
        XCTAssertEqual(
            AutomationJob.step1ArchiveFolder(for: URL(fileURLWithPath: "/tmp/Session/Ready MIX")).path,
            "/tmp/Session/Ready MIX/Step 1"
        )
        XCTAssertEqual(
            AutomationJob.step2ArchiveFolder(for: URL(fileURLWithPath: "/tmp/Session/Ready MIX")).path,
            "/tmp/Session/Ready MIX/Step 2"
        )
    }
}
