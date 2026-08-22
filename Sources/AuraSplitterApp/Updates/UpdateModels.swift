import Foundation

/// Semantic version parsed from release tags such as "v1.2.3" or "1.2.3".
/// Non-semver tags sort below any parseable version so stale tags never win.
struct SemanticVersion: Comparable, Equatable {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: String?

    init?(string raw: String) {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") || text.hasPrefix("V") {
            text.removeFirst()
        }
        let parts = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        let numbers = parts[0].split(separator: ".")
        guard numbers.count == 3,
              let major = Int(numbers[0]),
              let minor = Int(numbers[1]),
              let patch = Int(numbers[2])
        else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
        prerelease = parts.count > 1 ? String(parts[1]) : nil
    }

    var displayString: String {
        prerelease.map { "\(major).\(minor).\(patch)-\($0)" } ?? "\(major).\(minor).\(patch)"
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let left = (lhs.major, lhs.minor, lhs.patch)
        let right = (rhs.major, rhs.minor, rhs.patch)
        if left != right { return left < right }
        // 1.0.0 < 1.0.0-beta
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil): return false
        case (.some, nil): return true
        case (nil, .some): return false
        case (.some(let a), .some(let b)): return a < b
        }
    }
}

/// The running app's version, sourced from CFBundleShortVersionString in the
/// staged Info.plist (release pipeline and build_and_run.sh both write it).
enum AppVersion {
    static let unknown = "0.0.0"

    static var current: String {
        let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return (raw?.isEmpty == false) ? raw! : unknown
    }

    static var currentSemantic: SemanticVersion? {
        SemanticVersion(string: current)
    }
}

/// A parsed GitHub release that carries an installable app archive.
struct AppReleaseInfo: Equatable {
    let version: SemanticVersion
    let tagName: String
    let title: String
    let notesURL: String?
    /// .zip asset containing AuraSplitter.app — used by the in-app updater.
    let downloadURL: URL
    let downloadSizeBytes: Int?
    /// SHA-256 of the zip, published in the release body ("sha256(zip) = <hex>").
    let zipSHA256: String?
    let dmgURL: URL?
}

enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate(currentVersion: String)
    case available(AppReleaseInfo)
    case downloading(release: AppReleaseInfo, fraction: Double)
    case readyToInstall(release: AppReleaseInfo, stagedAppURL: URL)
    case failed(message: String)

    var isTerminalFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// Result of evaluating whether an update may be installed right now.
enum UpdateInstallGate: Equatable {
    case allowed
    case busy
    case unsavedWork(reasons: [String])

    static func evaluate(isBusy: Bool, unsavedReasons: [String]) -> UpdateInstallGate {
        if isBusy { return .busy }
        if !unsavedReasons.isEmpty { return .unsavedWork(reasons: unsavedReasons) }
        return .allowed
    }
}

enum UpdateConstants {
    static let repoOwner = "Pavan-Gopa"
    static let repoName = "AuraSplitter"
    /// Overridable for testing (AURA_UPDATES_API_URL); defaults to GitHub Releases.
    static var releasesAPIURL: URL {
        if let raw = ProcessInfo.processInfo.environment["AURA_UPDATES_API_URL"],
           let url = URL(string: raw) {
            return url
        }
        return URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest")!
    }
    static let autoCheckDefaultsKey = "AuraSplitter.autoCheckUpdates"
    static let lastCheckDefaultsKey = "AuraSplitter.lastUpdateCheckAt"
    static let autoCheckIntervalSeconds: TimeInterval = 6 * 60 * 60
    static let autoCheckInitialDelaySeconds: TimeInterval = 20
}
