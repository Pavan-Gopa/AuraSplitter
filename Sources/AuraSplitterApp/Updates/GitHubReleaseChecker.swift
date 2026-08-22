import Foundation

/// Abstraction so UpdateService can be tested without the network.
protocol ReleaseChecking {
    func latestRelease() async throws -> AppReleaseInfo?
}

/// Abstraction for downloading the update archive with progress.
protocol ReleaseDownloading {
    func download(from url: URL, to destination: URL, progress: @escaping (Double) -> Void) async throws
}

struct GitHubReleaseChecker: ReleaseChecking {
    let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 20
            config.timeoutIntervalForResource = 60
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: config)
        }
    }

    func latestRelease() async throws -> AppReleaseInfo? {
        var request = URLRequest(url: UpdateConstants.releasesAPIURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("AuraSplitter-Updater", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UpdateError.network("GitHub returned a non-HTTP response")
        }
        switch http.statusCode {
        case 200:
            break
        case 404:
            return nil // No published releases yet.
        default:
            throw UpdateError.network("GitHub API returned HTTP \(http.statusCode)")
        }
        return try GitHubReleaseChecker.parse(data: data)
    }

    enum UpdateError: LocalizedError {
        case network(String)
        case malformedPayload(String)

        var errorDescription: String? {
            switch self {
            case .network(let message): return message
            case .malformedPayload(let message): return message
            }
        }
    }

    // MARK: - Parsing

    static func parse(data: Data) throws -> AppReleaseInfo? {
        let payload: GitHubRelease
        do {
            payload = try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            throw UpdateError.malformedPayload("Could not decode release payload: \(error.localizedDescription)")
        }
        if payload.draft { return nil }

        let zipAsset = preferredAsset(from: payload.assets, suffix: ".zip")
        guard let zipAsset else { return nil } // Release without an installable archive.
        guard let version = SemanticVersion(string: payload.tagName) else { return nil }

        return AppReleaseInfo(
            version: version,
            tagName: payload.tagName,
            title: payload.name ?? payload.tagName,
            notesURL: payload.htmlURL,
            downloadURL: URL(string: zipAsset.browserDownloadURL)!,
            downloadSizeBytes: zipAsset.size,
            zipSHA256: sha256FromBody(payload.body ?? "", assetName: zipAsset.name),
            dmgURL: preferredAsset(from: payload.assets, suffix: ".dmg").map { URL(string: $0.browserDownloadURL)! }
        )
    }

    private static func preferredAsset(from assets: [GitHubAsset], suffix: String) -> GitHubAsset? {
        let matching = assets.filter { $0.name.lowercased().hasSuffix(suffix) && !$0.state.isEmpty && $0.state == "uploaded" }
        // Prefer arm64 builds, then the newest name for determinism.
        return matching.first { $0.name.lowercased().contains("arm64") } ?? matching.sorted { $0.name > $1.name }.first
    }

    /// Release body convention (written by script/release.sh):
    ///   sha256(AuraSplitter-1.2.3-arm64.zip) = <64 hex chars>
    static func sha256FromBody(_ body: String, assetName: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"sha256\s*\([^)]*\)\s*[:=]\s*([0-9a-fA-F]{64})"#) else {
            return nil
        }
        let range = NSRange(body.startIndex..., in: body)
        guard let match = regex.firstMatch(in: body, range: range),
              let hexRange = Range(match.range(at: 1), in: body)
        else { return nil }
        return body[hexRange].lowercased()
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let name: String?
    let draft: Bool
    let prerelease: Bool
    let htmlURL: String
    let body: String?
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case draft
        case prerelease
        case htmlURL = "html_url"
        case body
        case assets
    }
}

struct GitHubAsset: Decodable {
    let name: String
    let size: Int
    let state: String
    let browserDownloadURL: String

    enum CodingKeys: String, CodingKey {
        case name
        case size
        case state
        case browserDownloadURL = "browser_download_url"
    }
}

/// Downloads via URLSessionDownloadDelegate so real byte progress is reported.
final class ReleaseDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let progressHandler: (Double) -> Void
    let destinationURL: URL
    private var continuation: CheckedContinuation<URL, Error>?

    init(destinationURL: URL, progressHandler: @escaping (Double) -> Void) {
        self.destinationURL = destinationURL
        self.progressHandler = progressHandler
    }

    func start(_ session: URLSession, url: URL) async throws -> URL {
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let task = session.downloadTask(with: url)
            task.delegate = self
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progressHandler(min(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0.999))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temp file is deleted when this method returns — capture it NOW.
        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: location, to: destinationURL)
            continuation?.resume(returning: destinationURL)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return } // didFinish already resumed on success.
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

struct URLSessionReleaseDownloader: ReleaseDownloading {
    func download(from url: URL, to destination: URL, progress: @escaping (Double) -> Void) async throws {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 30 * 60
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        let delegate = ReleaseDownloadDelegate(destinationURL: destination, progressHandler: progress)
        let finalURL = try await delegate.start(session, url: url)
        guard FileManager.default.fileExists(atPath: finalURL.path) else {
            throw GitHubReleaseChecker.UpdateError.network("Downloaded update archive went missing")
        }
        progress(1.0)
    }
}
