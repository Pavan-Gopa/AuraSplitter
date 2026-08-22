import XCTest

@testable import AuraSplitterApp

final class SemanticVersionTests: XCTestCase {
    func testParsesPlainAndPrefixedTags() {
        XCTAssertEqual(SemanticVersion(string: "1.2.3")?.displayString, "1.2.3")
        XCTAssertEqual(SemanticVersion(string: "v2.10.0")?.displayString, "2.10.0")
        XCTAssertEqual(SemanticVersion(string: "  v0.1.0  ")?.displayString, "0.1.0")
    }

    func testRejectsNonSemver() {
        XCTAssertNil(SemanticVersion(string: "abc"))
        XCTAssertNil(SemanticVersion(string: "1.2"))
        XCTAssertNil(SemanticVersion(string: ""))
    }

    func testOrderingIncludesPrerelease() {
        let a = SemanticVersion(string: "1.0.0")!
        let b = SemanticVersion(string: "1.0.0-beta")!
        let c = SemanticVersion(string: "1.0.1")!
        XCTAssertTrue(b < a)
        XCTAssertTrue(a < c)
    }
}

final class GitHubReleaseParsingTests: XCTestCase {
    private func payload(assets: [[String: Any]], body: String = "", draft: Bool = false) -> Data {
        let obj: [String: Any] = [
            "tag_name": "v9.9.9",
            "name": "AuraSplitter 9.9.9",
            "draft": draft,
            "prerelease": false,
            "html_url": "https://github.com/Pavan-Gopa/KirtanSplitter/releases/tag/v9.9.9",
            "body": body,
            "assets": assets,
        ]
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    func testParsesReleaseWithZipAssetAndSha256FromBody() throws {
        let assets: [[String: Any]] = [
            ["name": "AuraSplitter-9.9.9-arm64.zip", "size": 1234,
             "state": "uploaded", "browser_download_url": "https://example.org/a.zip"],
            ["name": "AuraSplitter-9.9.9-arm64.dmg", "size": 5000,
             "state": "uploaded", "browser_download_url": "https://example.org/a.dmg"],
        ]
        let shaHex = String(repeating: "ab", count: 32)
        let release = try XCTUnwrap(
            GitHubReleaseChecker.parse(
                data: payload(assets: assets, body: "notes\nsha256(AuraSplitter-9.9.9-arm64.zip) = \(shaHex)")
            )
        )
        XCTAssertEqual(release.version.displayString, "9.9.9")
        XCTAssertEqual(release.downloadURL.absoluteString, "https://example.org/a.zip")
        XCTAssertEqual(release.dmgURL?.absoluteString, "https://example.org/a.dmg")
        XCTAssertEqual(release.zipSHA256, shaHex)
        XCTAssertEqual(release.downloadSizeBytes, 1234)
    }

    func testDraftAndZiplessReleasesAreIgnored() {
        let dmgOnly: [[String: Any]] = [
            ["name": "AuraSplitter-9.9.9-arm64.dmg", "size": 1,
             "state": "uploaded", "browser_download_url": "https://example.org/a.dmg"],
        ]
        XCTAssertNil(try GitHubReleaseChecker.parse(data: payload(assets: dmgOnly)))
        XCTAssertNil(try GitHubReleaseChecker.parse(data: payload(assets: [], draft: true)))
    }
}

final class UpdateInstallGateTests: XCTestCase {
    func testBusyWinsOverUnsavedWork() {
        XCTAssertEqual(
            UpdateInstallGate.evaluate(isBusy: true, unsavedReasons: ["queue"]),
            .busy
        )
    }

    func testUnsavedWorkReportedWhenIdle() {
        XCTAssertEqual(
            UpdateInstallGate.evaluate(isBusy: false, unsavedReasons: ["3 file(s)"]),
            .unsavedWork(reasons: ["3 file(s)"])
        )
    }

    func testAllowedWhenIdleAndSaved() {
        XCTAssertEqual(UpdateInstallGate.evaluate(isBusy: false, unsavedReasons: []), .allowed)
    }
}

final class UpdateInstallerScriptTests: XCTestCase {
    private func render(
        pid: pid_t,
        current: String,
        staged: String,
        relaunch: Bool
    ) -> String {
        let plan = UpdateInstaller.InstallPlan(
            pidToWaitFor: pid,
            currentAppBundleURL: URL(fileURLWithPath: current),
            stagedAppBundleURL: URL(fileURLWithPath: staged),
            logFileURL: URL(fileURLWithPath: "/tmp/installer.log"),
            relaunchAfterInstall: relaunch
        )
        return UpdateInstaller.renderScript(plan: plan)
    }

    func testScriptWaitsForPidSwapsBundlesAndRelaunches() {
        let script = render(
            pid: 42_042,
            current: "/Applications/AuraSplitter.app",
            staged: "/tmp/staging/AuraSplitter.app",
            relaunch: true
        )
        XCTAssertTrue(script.contains("WAIT_PID=42042"))
        XCTAssertTrue(script.contains("'/Applications/AuraSplitter.app'"))
        XCTAssertTrue(script.contains("'/tmp/staging/AuraSplitter.app'"))
        XCTAssertTrue(script.contains("RELAUNCH=1"))
        XCTAssertTrue(script.contains("open -n"))
        // Rollback path exists for failed installs.
        XCTAssertTrue(script.contains("mv \"$BACKUP\" \"$CURRENT_APP\""))
    }

    func testRelaunchDisabledKeepsOpenBehindRuntimeFlag() {
        let script = render(
            pid: 7,
            current: "/a/AuraSplitter.app",
            staged: "/b/AuraSplitter.app",
            relaunch: false
        )
        XCTAssertTrue(script.contains("RELAUNCH=0"))
        // `open` stays guarded by the runtime flag rather than being stripped.
        XCTAssertTrue(script.contains("[ \"$RELAUNCH\" = \"1\" ]"))
    }
}
