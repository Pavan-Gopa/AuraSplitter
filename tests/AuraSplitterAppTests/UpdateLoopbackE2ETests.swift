import XCTest

@testable import AuraSplitterApp

/// End-to-end check over a real HTTP loopback server: spins up `python3 -m
/// http.server`, serves a GitHub-Releases-shaped payload plus an installable
/// zip, and drives GitHubReleaseChecker + UpdateService download/verify path.
final class UpdateLoopbackE2ETests: XCTestCase {
    private var serverProcess: Process!
    private var serveDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        serveDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aura-update-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: serveDir, withIntermediateDirectories: true)

        // Minimal "AuraSplitter.app" archive so extraction succeeds too.
        let appURL = serveDir.appendingPathComponent("payload/AuraSplitter.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: appURL.appendingPathComponent("Contents/MacOS", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("stub".utf8).write(to: appURL.appendingPathComponent("Contents/MacOS/AuraSplitter"))
        // Ad-hoc signature so the structural codesign check passes in tests.
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", appURL.path]
        sign.standardOutput = Pipe(); sign.standardError = Pipe()
        try sign.run(); sign.waitUntilExit()
        let zipURL = serveDir.appendingPathComponent("AuraSplitter-99.0.0-arm64.zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zip.arguments = ["-c", "-k", "--keepParent",
                         appURL.path, zipURL.path]
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0 else {
            throw XCTSkip("ditto unavailable")
        }

        let sha = try UpdateVerifier.sha256Hex(of: zipURL)
        let json = """
        {"tag_name":"v99.0.0","name":"AuraSplitter 99.0.0","draft":false,"prerelease":false,
         "html_url":"https://example.org/release","body":"sha256(AuraSplitter-99.0.0-arm64.zip) = \(sha)",
         "assets":[{"name":"AuraSplitter-99.0.0-arm64.zip","size":\(zipSize(zipURL)),"state":"uploaded",
                    "browser_download_url":"http://127.0.0.1:\(port)/AuraSplitter-99.0.0-arm64.zip"}]}
        """
        try Data(json.utf8).write(to: serveDir.appendingPathComponent("releases.json"))
        serverProcess = Process()
        serverProcess.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        serverProcess.arguments = ["-m", "http.server", "\(port)", "--bind", "127.0.0.1",
                                   "--directory", serveDir.path]
        try serverProcess.run()

        // Wait for the port to open (max ~5s).
        for _ in 0..<50 {
            if (try? waitForTCP()) == true { return }
            usleep(100_000)
        }
        XCTFail("loopback http server did not start")
    }

    override func tearDownWithError() throws {
        serverProcess?.terminate()
        try? FileManager.default.removeItem(at: serveDir)
        try super.tearDownWithError()
    }

    private let port = 18_765

    private func zipSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    private func waitForTCP() throws -> Bool {
        let socket = Process()
        socket.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        socket.arguments = ["-z", "127.0.0.1", "\(port)"]
        try socket.run()
        socket.waitUntilExit()
        return socket.terminationStatus == 0
    }

    @MainActor
    func testCheckerAndDownloadFlowAgainstLoopbackServer() async throws {
        setenv("AURA_UPDATES_API_URL", "http://127.0.0.1:\(port)/releases.json", 1)
        defer { unsetenv("AURA_UPDATES_API_URL") }

        // 1. Checker resolves the release over HTTP and parses the payload.
        let checker = GitHubReleaseChecker()
        let fetched = try await checker.latestRelease()
        let release = try XCTUnwrap(fetched)
        XCTAssertEqual(release.version.displayString, "99.0.0")
        XCTAssertNotNil(release.zipSHA256)

        // 2. Service downloads, verifies SHA-256, extracts the app bundle.
        let service = UpdateService(checker: checker)
        service.state = .available(release)
        await service.downloadAndPrepare()

        guard case .readyToInstall(let ready, let stagedApp) = service.state else {
            if case .failed(let message) = service.state {
                XCTFail("expected readyToInstall, got failure: \(message)")
            } else {
                XCTFail("expected readyToInstall, got \(service.state)")
            }
            return
        }
        XCTAssertEqual(ready.version.displayString, "99.0.0")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedApp.path))
        // Signature verification is skipped for ad-hoc/test builds (no Team ID);
        // the structural checks above are what this stubbed bundle can satisfy.
    }
}
