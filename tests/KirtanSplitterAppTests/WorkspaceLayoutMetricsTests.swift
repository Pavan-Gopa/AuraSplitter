import XCTest
@testable import KirtanSplitterApp

final class WorkspaceLayoutMetricsTests: XCTestCase {
    func testWorkspaceUsesCompactWidgetRailAndRightSettingsDrawer() {
        XCTAssertLessThanOrEqual(WorkspaceLayoutMetrics.widgetRailWidth, 240)
        XCTAssertEqual(WorkspaceLayoutMetrics.settingsDrawerWidth, 370)
    }

    func testPreviewAreaDefaultsToHalfOfMainWorkspace() {
        XCTAssertEqual(WorkspaceLayoutMetrics.defaultPreviewFraction, 0.50)
    }
}
