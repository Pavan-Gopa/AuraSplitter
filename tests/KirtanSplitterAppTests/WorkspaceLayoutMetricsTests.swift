import XCTest
@testable import KirtanSplitterApp

final class WorkspaceLayoutMetricsTests: XCTestCase {
    func testWorkspaceUsesCompactWidgetRailAndRightSettingsDrawer() {
        XCTAssertLessThanOrEqual(WorkspaceLayoutMetrics.widgetRailWidth, 240)
        XCTAssertEqual(WorkspaceLayoutMetrics.settingsDrawerWidth, 370)
    }

    func testWorkspaceUsesSeparatedHeaderWithProminentSettingsToggle() {
        XCTAssertEqual(WorkspaceLayoutMetrics.appHeaderHeight, 72)
        XCTAssertGreaterThanOrEqual(WorkspaceLayoutMetrics.settingsToggleButtonSize, 36)
    }

    func testPreviewAreaDefaultsToHalfOfMainWorkspace() {
        XCTAssertEqual(WorkspaceLayoutMetrics.defaultPreviewFraction, 0.50)
    }

    func testModelPresetMenuUsesSmallStatusDotAndReadablePopoverWidth() {
        XCTAssertLessThanOrEqual(WorkspaceLayoutMetrics.modelPresetStatusDotSize, 4)
        XCTAssertGreaterThanOrEqual(WorkspaceLayoutMetrics.modelPresetMenuPopoverWidth, 240)
    }
}
