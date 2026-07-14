import SwiftUI

struct SettingsView: View {
    private let environment = ProcessInfo.processInfo.environment

    var body: some View {
        Form {
            Section("Runtime") {
                LabeledContent("Project root", value: environment["KIRTAN_SPLITTER_PROJECT_ROOT"] ?? FileManager.default.currentDirectoryPath)
                LabeledContent("Python", value: environment["KIRTAN_SPLITTER_PYTHON"] ?? ".venv/bin/python")
                LabeledContent("Models", value: environment["KIRTAN_SPLITTER_MODEL_DIR"] ?? ModelStoragePaths.defaultModelDirectory())
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
