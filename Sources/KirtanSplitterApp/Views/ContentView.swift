import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var backend = BackendClient()
    @StateObject private var previewPlayer = StemPreviewPlayer()

    @State private var inputURL: URL?
    @State private var outputDirectory: URL?
    @State private var settings = SeparationSettings()
    @State private var results: [StemFile] = []
    @State private var summary: SeparationSummary?
    @State private var isDropTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            ControlPaneView(
                backend: backend,
                inputURL: $inputURL,
                outputDirectory: $outputDirectory,
                settings: $settings,
                isDropTargeted: $isDropTargeted,
                startAction: startSeparation
            )
            .frame(width: 370)

            Divider()

            ResultsPaneView(
                backend: backend,
                results: results,
                summary: summary,
                previewPlayer: previewPlayer
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 980, minHeight: 660)
        .task {
            await startBackend()
        }
        .alert("Backend Error", isPresented: Binding(
            get: { backend.errorMessage != nil },
            set: { if !$0 { backend.errorMessage = nil } }
        )) {
            Button("OK") { backend.errorMessage = nil }
        } message: {
            Text(backend.errorMessage ?? "")
        }
    }

    private func startBackend() async {
        do {
            try await backend.start()
            await backend.loadInitialData()
        } catch {
            backend.errorMessage = error.localizedDescription
        }
    }

    private func startSeparation() {
        guard let inputURL else { return }
        let outputDir = resolvedOutputDirectory(for: inputURL)

        Task {
            do {
                let nextSummary = try await backend.separate(
                    inputURL: inputURL,
                    outputDirectory: outputDir,
                    settings: settings
                )
                await MainActor.run {
                    summary = nextSummary
                    results = nextSummary.files.sorted { $0.stem < $1.stem }
                }
            } catch {
                await MainActor.run {
                    backend.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func resolvedOutputDirectory(for input: URL) -> URL {
        if let outputDirectory {
            return outputDirectory.appendingPathComponent(input.deletingPathExtension().lastPathComponent)
        }
        return input
            .deletingLastPathComponent()
            .appendingPathComponent(input.deletingPathExtension().lastPathComponent + "_stems")
    }
}
