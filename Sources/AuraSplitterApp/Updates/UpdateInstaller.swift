import Foundation

/// Installs a staged update by swapping the app bundle after the running
/// instance exits. The installer runs as a detached process so it survives
/// NSApp.terminate() and relaunches the freshly installed bundle.
enum UpdateInstaller {
    struct InstallPlan {
        let pidToWaitFor: pid_t
        let currentAppBundleURL: URL
        let stagedAppBundleURL: URL
        let logFileURL: URL
        let relaunchAfterInstall: Bool
    }

    static func updatesDirectory() -> URL {
        let base = ModelStoragePaths.applicationSupportDirectory()
        let dir = URL(fileURLWithPath: base).appendingPathComponent("updates", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Generates and launches the detached installer. Returns the script URL
    /// (for logs/diagnostics).
    @discardableResult
    static func launchDetachedInstaller(plan: InstallPlan) throws -> URL {
        let scriptURL = updatesDirectory()
            .appendingPathComponent("install-\(Int(Date().timeIntervalSince1970)).sh", isDirectory: false)
        let script = renderScript(plan: plan)
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        // Same setsid pattern the backend launcher uses: fully detached from
        // this process so it survives NSApp.terminate().
        let perl = Process()
        perl.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        perl.arguments = [
            "-MPOSIX=setsid",
            "-e", "exit 0 if fork; setsid(); exec @ARGV or die $!",
            "/bin/bash",
            scriptURL.path,
        ]
        try perl.run()
        return scriptURL
    }

    static func renderScript(plan: InstallPlan) -> String {
        """
        #!/bin/bash
        # AuraSplitter in-place updater (auto-generated; safe to delete when done).
        set -uo pipefail

        CURRENT_APP=\(quoted(plan.currentAppBundleURL.path))
        STAGED_APP=\(quoted(plan.stagedAppBundleURL.path))
        TARGET_PARENT="$(dirname "$CURRENT_APP")"
        LOG=\(quoted(plan.logFileURL.path))
        WAIT_PID=\(plan.pidToWaitFor)
        RELAUNCH=\(plan.relaunchAfterInstall ? "1" : "0")

        log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >>"$LOG"; }

        log "installer started (waiting for pid $WAIT_PID)"

        # 1. Wait for the running app to exit (up to ~45s).
        for _ in $(seq 1 150); do
          if ! kill -0 "$WAIT_PID" 2>/dev/null; then
            break
          fi
          sleep 0.3
        done
        if kill -0 "$WAIT_PID" 2>/dev/null; then
          log "ERROR app still running after timeout; aborting without changes"
          exit 3
        fi
        log "app exited; installing"

        # 2. Swap bundles with rollback on failure.
        BACKUP="$TARGET_PARENT/.AuraSplitter.old.$(date +%s)"
        if ! mv "$CURRENT_APP" "$BACKUP"; then
          log "ERROR could not move old bundle aside"
          exit 4
        fi
        # Strip quarantine so Gatekeeper does not re-prompt on our own signed update.
        xattr -dr com.apple.quarantine "$STAGED_APP" 2>/dev/null || true
        if mv "$STAGED_APP" "$CURRENT_APP"; then
          rm -rf "$BACKUP"
          log "install complete"
          if [ "$RELAUNCH" = "1" ]; then
            sleep 1
            open -n "$CURRENT_APP"
            log "relaunched"
          fi
          exit 0
        fi

        mv "$BACKUP" "$CURRENT_APP"
        log "ERROR install failed; previous version restored"
        exit 5
        """
    }

    private static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
