import SwiftUI

struct SettingsView: View {
    private let environment = ProcessInfo.processInfo.environment
    @ObservedObject private var updateService = UpdateService.shared

    var body: some View {
        Form {
            Section("Runtime") {
                LabeledContent("Project root", value: environment["KIRTAN_SPLITTER_PROJECT_ROOT"] ?? FileManager.default.currentDirectoryPath)
                LabeledContent("Python", value: environment["KIRTAN_SPLITTER_PYTHON"] ?? ".venv/bin/python")
                LabeledContent("Models", value: environment["KIRTAN_SPLITTER_MODEL_DIR"] ?? ModelStoragePaths.defaultModelDirectory())
            }

            Section("Updates") {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { updateService.autoCheckEnabled },
                    set: { enabled in
                        updateService.autoCheckEnabled = enabled
                        if enabled { updateService.startAutoChecks() } else { updateService.stopAutoChecks() }
                    }
                ))
                if let lastCheckedAt = updateService.lastCheckedAt {
                    LabeledContent("Last checked", value: lastCheckedAt.formatted(date: .abbreviated, time: .shortened))
                }
                Button("Check for Updates Now") {
                    Task { await updateService.checkForUpdates(manual: true) }
                }
            }

            Section("Requirements") {
                Text("Apple Silicon macOS 13+, Python 3.10+, ffmpeg, mlx-audio-separator.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 560, height: 250)
    }
}
