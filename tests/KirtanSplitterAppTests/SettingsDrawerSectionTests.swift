import XCTest
@testable import KirtanSplitterApp

final class SettingsDrawerSectionTests: XCTestCase {
    func testSettingsDrawerUsesFourTwoByTwoSections() {
        XCTAssertEqual(SettingsDrawerSection.allCases.map(\.title), ["Process", "Models", "Last Run", "Logs"])
        XCTAssertEqual(WorkspaceLayoutMetrics.settingsDrawerTabColumnCount, 2)
    }
}
