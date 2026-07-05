import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var backend = BackendClient()
    @StateObject private var previewPlayer = StemPreviewPlayer()
    @StateObject private var sourcePreviewPlayer = AudioPreviewPlayer()

    @State private var inputURL: URL?
    @State private var outputDirectory: URL?
    @State private var settings = SeparationSettings()
    @State private var results: [StemFile] = []
    @State private var summary: SeparationSummary?
    @State private var sourceAnalysis: AudioAnalysis?
    @State private var sourceAnalysisError: String?
    @State private var isAnalyzingSource = false
    @State private var isDropTargeted = false

    var body: some View {
        ZStack {
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

                centerWorkspace
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                DiagnosticsInspectorView(backend: backend)
                    .frame(width: 310)
            }

            if let message = backend.modelSetupMessage {
                ModelSetupOverlay(message: message)
            }
        }
        .frame(minWidth: 1220, minHeight: 700)
        .task {
            await startBackend()
        }
        .onChange(of: inputURL) { nextURL in
            handleInputChange(nextURL)
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

    private var centerWorkspace: some View {
        GeometryReader { geometry in
            let topHeight = min(max(300, geometry.size.height * 0.62), max(260, geometry.size.height - 230))

            VStack(spacing: 0) {
                SourceResultOverviewView(
                    backend: backend,
                    inputURL: inputURL,
                    sourceAnalysis: sourceAnalysis,
                    analysisError: sourceAnalysisError,
                    results: results,
                    summary: summary,
                    previewPlayer: previewPlayer
                )
                .frame(height: topHeight)

                Divider()

                AudioPreviewPane(
                    analysis: sourceAnalysis,
                    analysisError: sourceAnalysisError,
                    isAnalyzing: isAnalyzingSource,
                    player: sourcePreviewPlayer
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func startBackend() async {
        do {
            try await backend.start()
            await backend.loadInitialData()
            if let inputURL {
                await analyzeInput(inputURL)
            }
        } catch {
            backend.errorMessage = error.localizedDescription
        }
    }

    private func handleInputChange(_ nextURL: URL?) {
        sourcePreviewPlayer.stop()
        previewPlayer.stop()
        results = []
        summary = nil
        Task {
            await analyzeInput(nextURL)
        }
    }

    @MainActor
    private func analyzeInput(_ url: URL?) async {
        sourceAnalysis = nil
        sourceAnalysisError = nil
        isAnalyzingSource = false
        guard let url else { return }
        guard backend.isReady else { return }

        isAnalyzingSource = true
        defer {
            if inputURL?.path == url.path {
                isAnalyzingSource = false
            }
        }

        do {
            let analysis = try await backend.analyzeAudio(url: url)
            guard inputURL?.path == url.path else { return }
            sourceAnalysis = analysis
        } catch {
            guard inputURL?.path == url.path else { return }
            sourceAnalysisError = error.localizedDescription
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

private struct ModelSetupOverlay: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("First model setup")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(maxWidth: 360)
        }
        .padding(22)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 18)
        .accessibilityElement(children: .combine)
    }
}
