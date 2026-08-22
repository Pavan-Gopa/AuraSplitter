import AppKit
import Combine
import Foundation
import UserNotifications

/// Orchestrates the full update lifecycle:
/// check → download → verify → (graceful gate) → detached install → relaunch.
@MainActor
final class UpdateService: ObservableObject {
    static let shared = UpdateService()

    @Published var state: UpdateState = .idle
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var installWhenIdlePending = false

    var autoCheckEnabled: Bool {
        get { UserDefaults.standard.object(forKey: UpdateConstants.autoCheckDefaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: UpdateConstants.autoCheckDefaultsKey) }
    }

    /// Provided by the app layer: true while a separation / backend lifecycle runs.
    var isBusyProvider: () -> Bool = { false }
    /// Provided by the app layer: human-readable descriptions of unsaved work.
    var unsavedWorkProvider: () -> [String] = { [] }

    private let checker: ReleaseChecking
    private let downloader: ReleaseDownloading
    private var autoCheckTask: Task<Void, Never>?
    private var currentWorkDirectory: URL?

    init(checker: ReleaseChecking = GitHubReleaseChecker(), downloader: ReleaseDownloading = URLSessionReleaseDownloader()) {
        self.checker = checker
        self.downloader = downloader
    }

    // MARK: - Auto checks

    func startAutoChecks() {
        guard autoCheckTask == nil else { return }
        autoCheckTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(UpdateConstants.autoCheckInitialDelaySeconds * 1_000_000_000))
            while !Task.isCancelled {
                guard let self, self.autoCheckEnabled else { break }
                await self.checkForUpdates(manual: false)
                try? await Task.sleep(nanoseconds: UInt64(UpdateConstants.autoCheckIntervalSeconds * 1_000_000_000))
            }
        }
    }

    func stopAutoChecks() {
        autoCheckTask?.cancel()
        autoCheckTask = nil
    }

    // MARK: - Check

    func checkForUpdates(manual: Bool) async {
        guard !isTransitioning else { return }
        state = .checking
        do {
            let release = try await checker.latestRelease()
            lastCheckedAt = Date()
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: UpdateConstants.lastCheckDefaultsKey)

            guard let release else {
                state = .upToDate(currentVersion: AppVersion.current)
                return
            }
            if release.version > (AppVersion.currentSemantic ?? SemanticVersion(string: "0.0.0")!) {
                state = .available(release)
                if !manual { notifyUpdateAvailable(release) }
            } else {
                state = .upToDate(currentVersion: AppVersion.current)
            }
        } catch {
            state = .failed(message: error.localizedDescription)
            if manual { presentOKAlert(title: "Update Check Failed", message: error.localizedDescription) }
        }
    }

    private var isTransitioning: Bool {
        switch state {
        case .idle, .upToDate, .available, .failed: return false
        case .checking, .downloading, .readyToInstall: return true
        }
    }

    // MARK: - Download + verify

    func downloadAndPrepare() async {
        guard case .available(let release) = state else { return }
        state = .downloading(release: release, fraction: 0)

        let workDir = Self.makeWorkDirectory(for: release)
        currentWorkDirectory = workDir
        let zipURL = workDir.appendingPathComponent(release.downloadURL.lastPathComponent)

        do {
            try await downloader.download(from: release.downloadURL, to: zipURL) { [weak self] fraction in
                Task { @MainActor [weak self] in
                    if case .downloading(let r, _) = self?.state, r == release {
                        self?.state = .downloading(release: r, fraction: fraction)
                    }
                }
            }

            if let expected = release.zipSHA256 {
                let actual = try UpdateVerifier.sha256Hex(of: zipURL)
                guard actual == expected.lowercased() else {
                    throw UpdateVerifier.VerificationError.sha256Mismatch(expected: expected, actual: actual)
                }
            }

            let stagedAppURL = try UpdateVerifier.extractApp(from: zipURL, workDirectory: workDir)
            try UpdateVerifier.verifyCodeSignature(of: stagedAppURL, currentAppURL: Bundle.main.bundleURL)
            try? FileManager.default.removeItem(at: zipURL) // Verified; archive no longer needed.
            state = .readyToInstall(release: release, stagedAppURL: stagedAppURL)
        } catch {
            cleanupWorkDirectory()
            state = .failed(message: error.localizedDescription)
        }
    }

    private static func makeWorkDirectory(for release: AppReleaseInfo) -> URL {
        let dir = updatesRoot()
            .appendingPathComponent("staging-\(release.version.displayString)-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func updatesRoot() -> URL {
        URL(fileURLWithPath: ModelStoragePaths.applicationSupportDirectory())
            .appendingPathComponent("updates", isDirectory: true)
    }

    // MARK: - Install with graceful gate

    /// Entry point from UI. Applies the busy/unsaved-work gates and either
    /// installs now or schedules the install for when the app drains.
    func requestInstall() {
        let gate = UpdateInstallGate.evaluate(isBusy: isBusyProvider(), unsavedReasons: unsavedWorkProvider())
        switch gate {
        case .busy:
            installWhenIdlePending = true
            presentOKAlert(
                title: "Finishing Current Work",
                message: "AuraSplitter is still processing.\nThe update will install automatically as soon as all tasks finish — you can keep working until then."
            )
        case .unsavedWork(let reasons):
            if presentUnsavedWorkAlert(reasons: reasons) {
                beginInstallSequence()
            }
        case .allowed:
            beginInstallSequence()
        }
    }

    /// Called by the UI when a busy app becomes idle and an install is pending.
    func performInstallIfPending() {
        guard installWhenIdlePending else { return }
        installWhenIdlePending = false
        guard case .readyToInstall = state else { return }
        beginInstallSequence()
    }

    private func beginInstallSequence() {
        guard case .readyToInstall(let release, let stagedAppURL) = state else { return }

        let confirm = presentInstallConfirmationAlert(
            version: release.version.displayString,
            notesURL: release.notesURL
        )
        guard confirm else { return }

        let plan = UpdateInstaller.InstallPlan(
            pidToWaitFor: ProcessInfo.processInfo.processIdentifier,
            currentAppBundleURL: Bundle.main.bundleURL,
            stagedAppBundleURL: stagedAppURL,
            logFileURL: UpdateInstaller.updatesDirectory().appendingPathComponent("installer.log"),
            relaunchAfterInstall: true
        )
        do {
            _ = try UpdateInstaller.launchDetachedInstaller(plan: plan)
            state = .idle // Installer takes over; app terminates below.
            NSApp.terminate(nil)
        } catch {
            state = .failed(message: error.localizedDescription)
            presentOKAlert(title: "Could Not Start Installer", message: error.localizedDescription)
        }
    }

    // MARK: - Notifications

    private func notifyUpdateAvailable(_ release: AppReleaseInfo) {
        guard NSApp.isActive == false || true else { return } // Always surface; gentle.
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "AuraSplitter \(release.version.displayString) available"
            content.body = "Open AuraSplitter to download and install the update."
            let request = UNNotificationRequest(identifier: "update-\(release.tagName)", content: content, trigger: nil)
            center.add(request)
        }
    }

    // MARK: - Alerts

    @discardableResult
    private func presentUnsavedWorkAlert(reasons: [String]) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Save your project before updating?"
        alert.informativeText = "Unsaved changes were found:\n• " + reasons.joined(separator: "\n• ")
            + "\n\nYou can cancel, save via Settings, and run the update again."
        alert.addButton(withTitle: "Discard Changes and Update")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func presentInstallConfirmationAlert(version: String, notesURL: String?) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Install AuraSplitter \(version)?"
        alert.informativeText = "The app will quit, the update will be installed over the current version, and AuraSplitter will start again."
        alert.addButton(withTitle: "Quit and Install")
        alert.addButton(withTitle: "Later")
        if notesURL != nil {
            alert.showsSuppressionButton = false
        }
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func presentOKAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    // MARK: - Cleanup

    private func cleanupWorkDirectory() {
        guard let dir = currentWorkDirectory else { return }
        try? FileManager.default.removeItem(at: dir)
        currentWorkDirectory = nil
    }
}
