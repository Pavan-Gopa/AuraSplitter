import SwiftUI

struct ContentView: View {
    @StateObject private var backend = BackendClient()
    @StateObject private var audioPreviewPlayer = AudioPreviewPlayer()

    @State private var sources: [BatchSourceItem] = []
    @State private var outputDirectory: URL?
    @State private var settings = SeparationSettings()
    @State private var resultGroups: [BatchResultGroup] = []
    @State private var previewSelection: AudioPreviewSelection = .none
    @State private var previewAnalysis: AudioAnalysis?
    @State private var previewAnalysisError: String?
    @State private var isAnalyzingPreview = false
    @State private var isDropTargeted = false

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                ControlPaneView(
                    backend: backend,
                    outputDirectory: $outputDirectory,
                    settings: $settings,
                    isDropTargeted: $isDropTargeted,
                    sources: sources,
                    chooseFilesAction: loadInputFiles,
                    chooseFolderAction: loadInputFolder,
                    droppedURLAction: handleDroppedURL,
                    startAction: startBatchSeparation
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
                    sources: $sources,
                    presets: backend.presets,
                    resultGroups: resultGroups,
                    previewSelection: previewSelection,
                    previewSourceAction: previewSource,
                    previewStemAction: previewStem,
                    deleteStemAction: deleteStem
                )
                .frame(height: topHeight)

                Divider()

                AudioPreviewPane(
                    analysis: previewAnalysis,
                    analysisError: previewAnalysisError,
                    isAnalyzing: isAnalyzingPreview,
                    player: audioPreviewPlayer
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func startBackend() async {
        do {
            try await backend.start()
            await backend.loadInitialData()
            analyzeLoadedSources()
        } catch {
            backend.errorMessage = error.localizedDescription
        }
    }

    private func loadInputFiles(_ urls: [URL]) {
        let nextSources = BatchWorkspace.makeSources(from: urls, defaultPresetID: settings.presetID)
        replaceSources(with: nextSources)
    }

    private func loadInputFolder(_ folder: URL) {
        let files = BatchWorkspace.audioFiles(in: folder)
        replaceSources(with: BatchWorkspace.makeSources(from: files, defaultPresetID: settings.presetID))
    }

    private func handleDroppedURL(_ url: URL) {
        if isDirectory(url) {
            loadInputFolder(url)
        } else {
            loadInputFiles([url])
        }
    }

    private func replaceSources(with nextSources: [BatchSourceItem]) {
        audioPreviewPlayer.stop()
        sources = nextSources
        resultGroups = []
        previewSelection = .none
        previewAnalysis = nil
        previewAnalysisError = nil
        isAnalyzingPreview = false

        guard let first = nextSources.first else { return }
        previewSelection = .source(first.id)
        isAnalyzingPreview = backend.isReady
        analyzeLoadedSources()
    }

    private func analyzeLoadedSources() {
        guard backend.isReady, !sources.isEmpty else { return }
        let ids = sources.map(\.id)
        Task {
            for id in ids {
                await analyzeSource(id: id)
            }
        }
    }

    private func previewSource(_ source: BatchSourceItem) {
        audioPreviewPlayer.stop()
        previewSelection = .source(source.id)
        previewAnalysis = source.analysis
        previewAnalysisError = source.analysisError
        isAnalyzingPreview = source.isAnalyzing

        if source.analysis == nil, source.analysisError == nil {
            Task {
                await analyzeSource(id: source.id)
            }
        }
    }

    private func previewStem(_ stem: StemFile) {
        audioPreviewPlayer.stop()
        let selection = AudioPreviewSelection.result(stem.path)
        previewSelection = selection
        previewAnalysis = nil
        previewAnalysisError = nil
        isAnalyzingPreview = true

        Task {
            await analyzePreviewFile(
                url: URL(fileURLWithPath: stem.path),
                selection: selection
            )
        }
    }

    @MainActor
    private func analyzeSource(id: String) async {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        let url = sources[index].url
        sources[index].isAnalyzing = true
        sources[index].analysisError = nil
        if previewSelection == .source(id) {
            isAnalyzingPreview = true
            previewAnalysisError = nil
        }

        do {
            let analysis = try await backend.analyzeAudio(url: url)
            guard let currentIndex = sources.firstIndex(where: { $0.id == id }) else { return }
            sources[currentIndex].analysis = analysis
            sources[currentIndex].analysisError = nil
            sources[currentIndex].isAnalyzing = false
            if previewSelection == .source(id) {
                previewAnalysis = analysis
                previewAnalysisError = nil
                isAnalyzingPreview = false
            }
        } catch {
            guard let currentIndex = sources.firstIndex(where: { $0.id == id }) else { return }
            sources[currentIndex].analysisError = error.localizedDescription
            sources[currentIndex].isAnalyzing = false
            if previewSelection == .source(id) {
                previewAnalysisError = error.localizedDescription
                isAnalyzingPreview = false
            }
        }
    }

    @MainActor
    private func analyzePreviewFile(url: URL, selection: AudioPreviewSelection) async {
        do {
            let analysis = try await backend.analyzeAudio(url: url)
            guard previewSelection == selection else { return }
            previewAnalysis = analysis
            previewAnalysisError = nil
            isAnalyzingPreview = false
        } catch {
            guard previewSelection == selection else { return }
            previewAnalysis = nil
            previewAnalysisError = error.localizedDescription
            isAnalyzingPreview = false
        }
    }

    private func startBatchSeparation() {
        let selectedSources = sources.filter(\.isSelectedForProcessing)
        guard !selectedSources.isEmpty else { return }

        Task {
            for source in selectedSources {
                var sourceSettings = settings
                sourceSettings.presetID = source.presetID
                let outputDir = resolvedOutputDirectory(for: source.url)

                do {
                    let nextSummary = try await backend.separate(
                        inputURL: source.url,
                        outputDirectory: outputDir,
                        settings: sourceSettings
                    )
                    await MainActor.run {
                        upsertResultGroup(sourceURL: source.url, summary: nextSummary)
                    }
                } catch {
                    await MainActor.run {
                        backend.errorMessage = "Failed \(source.fileName): \(error.localizedDescription)"
                    }
                    break
                }
            }
        }
    }

    private func upsertResultGroup(sourceURL: URL, summary: SeparationSummary) {
        let group = BatchResultGroup(
            sourceURL: sourceURL,
            summary: summary,
            files: summary.files.sorted { $0.stem < $1.stem }
        )
        if let index = resultGroups.firstIndex(where: { $0.id == group.id }) {
            resultGroups[index] = group
        } else {
            resultGroups.append(group)
        }
    }

    private func deleteStem(_ stem: StemFile) {
        do {
            if audioPreviewPlayer.playingPath == stem.path {
                audioPreviewPlayer.stop()
            }
            try BatchWorkspace.deleteStem(at: stem.path, from: &resultGroups)
            if previewSelection == .result(stem.path) {
                previewSelection = .none
                previewAnalysis = nil
                previewAnalysisError = nil
                isAnalyzingPreview = false
            }
        } catch {
            backend.errorMessage = "Could not delete \(stem.fileName): \(error.localizedDescription)"
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

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return isDirectory.boolValue
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
