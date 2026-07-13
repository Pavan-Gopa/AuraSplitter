import SwiftUI

struct ContentView: View {
    @StateObject private var backend = BackendClient()
    @StateObject private var audioPreviewPlayer = AudioPreviewPlayer()
    @StateObject private var processPresetStore = ProcessSettingsPresetStore()

    @State private var sources: [BatchSourceItem] = []
    @State private var outputDirectory: URL?
    @State private var settings = SeparationSettings()
    @State private var modelRatings: [String: Int] = (UserDefaults.standard.dictionary(forKey: "KirtanSplitter.modelRatings") as? [String: Int]) ?? [:]
    @State private var selectedModelIDs: Set<String> = ["kirtan_pro"]
    @State private var selectedStemPaths: Set<String> = []
    @State private var isShowingComparison = false
    @State private var selectedProcessPresetID = ProcessSettingsPreset.defaultPresetID
    @State private var resultGroups: [BatchResultGroup] = []
    @State private var previewSelection: AudioPreviewSelection = .none
    @State private var previewAnalysis: AudioAnalysis?
    @State private var previewAnalysisError: String?
    @State private var resultPreviewCache = AudioPreviewAnalysisCache()
    @State private var isAnalyzingPreview = false
    @State private var isDropTargeted = false
    @State private var previewHeightFraction = AudioPreviewLayout.defaultBottomFraction
    @State private var previewResizeStartFraction: CGFloat?
    @State private var isSettingsSidebarOpen = false
    @State private var settingsDrawerSection: SettingsDrawerSection = .process
    @State private var didInitializeLayout = false
    @State private var batchProcessingTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                AppHeaderView(
                    backend: backend,
                    modelPresetID: modelPresetIDBinding,
                    processPresetID: processPresetIDBinding,
                    modelPresets: backend.presets,
                    processPresets: processPresetStore.presets,
                    renderEstimate: backend.renderEstimate,
                    hasSelectedSources: hasSelectedSources,
                    isSettingsSidebarOpen: isSettingsSidebarOpen,
                    primaryAction: performPrimaryProcessAction,
                    settingsAction: toggleSettingsSidebar,
                    modelRatings: $modelRatings,
                    selectedModelIDs: $selectedModelIDs
                )
                .frame(height: WorkspaceLayoutMetrics.appHeaderHeight)

                Divider()

                HStack(spacing: 0) {
                    mainWorkspace
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if isSettingsSidebarOpen {
                        Divider()
                        SettingsDrawerView(
                            backend: backend,
                            processPresetStore: processPresetStore,
                            settings: $settings,
                            selectedProcessPresetID: processPresetIDBinding,
                            selectedSection: $settingsDrawerSection,
                            applyProcessPresetAction: applyProcessPreset,
                            closeAction: closeSettingsSidebar
                        )
                        .frame(width: WorkspaceLayoutMetrics.settingsDrawerWidth)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .animation(.easeInOut(duration: 0.18), value: isSettingsSidebarOpen)
            .onChange(of: backend.lastSummary?.completedAt) { _ in
                guard backend.lastSummary != nil else { return }
                // Surface Post Run Stats immediately after a finished separation.
                settingsDrawerSection = .run
                isSettingsSidebarOpen = true
            }

            if let message = backend.modelSetupMessage {
                ModelSetupOverlay(message: message)
            }

            if isShowingComparison {
                AudioComparisonView(
                    stems: selectedStemsToCompare,
                    player: audioPreviewPlayer,
                    backend: backend,
                    resultPreviewCache: $resultPreviewCache,
                    onClose: {
                        isShowingComparison = false
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                .zIndex(2)
            }
        }
        .frame(minWidth: 1220, minHeight: 700)
        .task {
            isSettingsSidebarOpen = false
            await startBackend()
        }
        .task(id: renderEstimateRefreshKey) {
            await refreshRenderEstimate()
        }
        .onAppear {
            guard !didInitializeLayout else { return }
            didInitializeLayout = true
            isSettingsSidebarOpen = false
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

    private var mainWorkspace: some View {
        GeometryReader { geometry in
            let handleHeight: CGFloat = 8
            let bottomFraction = AudioPreviewLayout.clampedBottomFraction(previewHeightFraction)
            let bottomHeight = max(220, (geometry.size.height - handleHeight) * bottomFraction)
            let topHeight = max(260, geometry.size.height - bottomHeight - handleHeight)

            VStack(spacing: 0) {
                topWorkspace
                .frame(height: topHeight)

                PreviewResizeHandle()
                    .frame(height: handleHeight)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if previewResizeStartFraction == nil {
                                    previewResizeStartFraction = previewHeightFraction
                                }
                                let startFraction = previewResizeStartFraction ?? previewHeightFraction
                                let nextFraction = startFraction - value.translation.height / max(1, geometry.size.height)
                                previewHeightFraction = AudioPreviewLayout.clampedBottomFraction(nextFraction)
                            }
                            .onEnded { _ in
                                previewResizeStartFraction = nil
                            }
                    )

                AudioPreviewPane(
                    analysis: previewAnalysis,
                    analysisError: previewAnalysisError,
                    isAnalyzing: isAnalyzingPreview,
                    previewProgress: backend.previewProgress,
                    player: audioPreviewPlayer
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var topWorkspace: some View {
        HStack(spacing: 0) {
            WorkspaceWidgetRailView(
                backend: backend,
                sources: sources,
                isDropTargeted: $isDropTargeted,
                chooseFilesAction: loadInputFiles,
                chooseFolderAction: loadInputFolder,
                droppedURLAction: handleDroppedURL
            )
            .frame(width: WorkspaceLayoutMetrics.widgetRailWidth)

            Divider()

            SourceResultOverviewView(
                backend: backend,
                sources: $sources,
                presets: backend.presets,
                usesPerSourcePresets: usesPerSourcePresets,
                resultGroups: resultGroups,
                previewSelection: previewSelection,
                previewSourceAction: previewSource,
                previewStemAction: previewStem,
                deleteStemAction: deleteStem,
                selectedStemPaths: $selectedStemPaths,
                compareAction: { isShowingComparison = true }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private func toggleSettingsSidebar() {
        withAnimation(.easeInOut(duration: 0.18)) {
            isSettingsSidebarOpen.toggle()
        }
    }

    private func closeSettingsSidebar() {
        withAnimation(.easeInOut(duration: 0.18)) {
            isSettingsSidebarOpen = false
        }
    }

    private var modelPresetIDBinding: Binding<String> {
        Binding(
            get: { settings.presetID },
            set: { presetID in
                settings.presetID = presetID
                if !selectedModelIDs.contains(presetID) {
                    selectedModelIDs = [presetID]
                }
                if usesPerSourcePresets {
                    for index in sources.indices where sources[index].isSelectedForProcessing {
                        sources[index].presetID = presetID
                    }
                }
            }
        )
    }

    private var processPresetIDBinding: Binding<String> {
        Binding(
            get: { selectedProcessPresetID },
            set: { presetID in
                selectedProcessPresetID = presetID
                applyProcessPreset(presetID)
            }
        )
    }

    private var hasSelectedSources: Bool {
        sources.contains { $0.isSelectedForProcessing }
    }

    private var selectedProcessPreset: ProcessSettingsPreset? {
        processPresetStore.preset(id: selectedProcessPresetID)
    }

    private var renderEstimateSource: BatchSourceItem? {
        sources.first { $0.isSelectedForProcessing } ?? sources.first
    }

    private var renderEstimateRefreshKey: String {
        guard backend.isReady, let source = renderEstimateSource else {
            return "not-ready"
        }
        let durationKey = source.analysis.map { String(format: "%.2f", $0.durationSeconds) } ?? "duration-pending"
        return [
            source.url.path,
            durationKey,
            settings.presetID,
            selectedModelIDs.sorted().joined(separator: ","),
            settings.modelOverride ?? "",
            selectedProcessPresetID,
            "\(settings.mdxcSegmentSize)",
            "\(settings.mdxcOverlap)",
            "\(settings.mdxcBatchSize)",
            settings.speedMode,
            backend.isBusy ? "busy" : "idle",
        ].joined(separator: "|")
    }

    private func applyProcessPreset(_ presetID: String) {
        guard let preset = processPresetStore.preset(id: presetID) else { return }
        preset.snapshot.apply(to: &settings)
    }

    @MainActor
    private func refreshRenderEstimate() async {
        guard backend.isReady, !backend.isBusy, let source = renderEstimateSource else {
            if sources.isEmpty {
                backend.renderEstimate = nil
            }
            return
        }

        let modelsToEstimate = selectedModelIDs.isEmpty ? [settings.presetID] : Array(selectedModelIDs)

        do {
            var totalEstimate: RenderEstimate? = nil
            for modelID in modelsToEstimate {
                var sourceSettings = settings
                sourceSettings.presetID = modelID
                let est = try await backend.fetchRenderEstimate(
                    inputURL: source.url,
                    durationSeconds: source.analysis?.durationSeconds,
                    settings: sourceSettings,
                    processPreset: selectedProcessPreset
                )
                if let total = totalEstimate {
                    totalEstimate = total.adding(est)
                } else {
                    totalEstimate = est
                }
            }
            backend.renderEstimate = totalEstimate
        } catch {
            backend.renderEstimate = nil
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
        resultPreviewCache.removeAll()
        selectedStemPaths = []
        previewSelection = .none
        previewAnalysis = nil
        previewAnalysisError = nil
        isAnalyzingPreview = false

        // Pull in any stems already on disk (e.g. previous experiments in Song_stems/).
        loadExistingResults(for: nextSources)

        guard let first = nextSources.first else { return }
        previewSelection = .source(first.id)
        isAnalyzingPreview = backend.isReady
        analyzeLoadedSources()
    }

    /// Scan each source's stems folder and populate Results without re-separating.
    private func loadExistingResults(for sources: [BatchSourceItem]) {
        var groups: [BatchResultGroup] = []
        for source in sources {
            let folder = resolvedOutputDirectory(for: source.url)
            let stems = BatchWorkspace.discoverStemFiles(in: folder, relatedTo: source.url)
            guard !stems.isEmpty else { continue }
            groups.append(
                BatchResultGroup(
                    sourceURL: source.url,
                    summary: nil,
                    files: stems
                )
            )
            prewarmResultPreviews(for: stems)
        }
        resultGroups = groups
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
        let path = source.url.path
        let previousTime = audioPreviewPlayer.currentTime
        
        previewSelection = .source(source.id)
        previewAnalysis = source.analysis
        previewAnalysisError = source.analysisError
        isAnalyzingPreview = source.isAnalyzing

        audioPreviewPlayer.seek(path: path, time: previousTime)

        if source.analysis == nil, source.analysisError == nil {
            Task {
                await analyzeSource(id: source.id)
            }
        }
    }

    private func previewStem(_ stem: StemFile) {
        let path = stem.path
        let previousTime = audioPreviewPlayer.currentTime
        
        let selection = AudioPreviewSelection.result(path)
        previewSelection = selection
        previewAnalysis = nil
        previewAnalysisError = nil
        isAnalyzingPreview = false

        audioPreviewPlayer.seek(path: path, time: previousTime)

        if applyCachedResultPreview(for: path) {
            return
        }

        Task {
            await analyzeResultStem(path: path)
        }
    }

    @MainActor
    private func analyzeSource(id: String) async {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        let url = sources[index].url

        // K8: disk-cached preview fast path (skips the backend round-trip
        // when the source file is unchanged since last analysis).
        if let cached = PreviewAnalysisDiskCache.shared.load(path: url.path) {
            sources[index].analysis = cached
            sources[index].analysisError = nil
            sources[index].isAnalyzing = false
            if previewSelection == .source(id) {
                previewAnalysis = cached
                previewAnalysisError = nil
                isAnalyzingPreview = false
            }
            return
        }

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
            PreviewAnalysisDiskCache.shared.store(analysis)
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

    @discardableResult
    private func applyCachedResultPreview(for path: String) -> Bool {
        if let analysis = resultPreviewCache.analysis(for: path) {
            previewAnalysis = analysis
            previewAnalysisError = nil
            isAnalyzingPreview = false
            return true
        }

        if let error = resultPreviewCache.error(for: path) {
            previewAnalysis = nil
            previewAnalysisError = error
            isAnalyzingPreview = false
            return true
        }

        if resultPreviewCache.isAnalyzing(path) {
            previewAnalysis = nil
            previewAnalysisError = nil
            isAnalyzingPreview = true
            return true
        }

        return false
    }

    @MainActor
    private func analyzeResultStem(path: String) async {
        let selection = AudioPreviewSelection.result(path)
        guard resultPreviewCache.shouldStartAnalysis(for: path) else {
            if previewSelection == selection {
                applyCachedResultPreview(for: path)
            }
            return
        }

        if previewSelection == selection {
            previewAnalysis = nil
            previewAnalysisError = nil
            isAnalyzingPreview = true
        }

        do {
            let url = URL(fileURLWithPath: path)
            let analysis = try await backend.analyzeAudio(url: url)
            guard FileManager.default.fileExists(atPath: path) else {
                resultPreviewCache.remove(path)
                if previewSelection == selection {
                    previewSelection = .none
                    previewAnalysis = nil
                    previewAnalysisError = nil
                    isAnalyzingPreview = false
                }
                return
            }
            resultPreviewCache.store(analysis, for: path)
            guard previewSelection == selection else { return }
            previewAnalysis = analysis
            previewAnalysisError = nil
            isAnalyzingPreview = false
        } catch {
            if !FileManager.default.fileExists(atPath: path) {
                resultPreviewCache.remove(path)
                if previewSelection == selection {
                    previewSelection = .none
                    previewAnalysis = nil
                    previewAnalysisError = nil
                    isAnalyzingPreview = false
                }
                return
            }
            resultPreviewCache.storeError(error.localizedDescription, for: path)
            guard previewSelection == selection else { return }
            previewAnalysis = nil
            previewAnalysisError = error.localizedDescription
            isAnalyzingPreview = false
        }
    }

    private func startBatchSeparation() {
        let selectedSources = sources.filter(\.isSelectedForProcessing)
        guard !selectedSources.isEmpty, batchProcessingTask == nil else { return }

        batchProcessingTask = Task {
            for source in selectedSources {
                if Task.isCancelled { break }

                let modelsToRun = usesPerSourcePresets ? [source.presetID] : (selectedModelIDs.isEmpty ? [settings.presetID] : selectedModelIDs.sorted())
                let outputDir = resolvedOutputDirectory(for: source.url)

                for modelID in modelsToRun {
                    if Task.isCancelled { break }

                    var sourceSettings = settings
                    sourceSettings.presetID = modelID

                    do {
                        let nextSummary = try await backend.separate(
                            inputURL: source.url,
                            outputDirectory: outputDir,
                            settings: sourceSettings,
                            processPreset: selectedProcessPreset
                        )
                        await MainActor.run {
                            upsertResultGroup(sourceURL: source.url, summary: nextSummary)
                            prewarmResultPreviews(for: nextSummary.files)
                        }
                    } catch BackendClientError.cancelled {
                        break
                    } catch is CancellationError {
                        break
                    } catch {
                        await MainActor.run {
                            backend.errorMessage = "Failed \(source.fileName): \(error.localizedDescription)"
                        }
                        break
                    }
                }
            }

            await MainActor.run {
                batchProcessingTask = nil
            }
        }
    }

    private func performPrimaryProcessAction() {
        let presentation = ProcessingControlPresentation(
            isReady: backend.isReady,
            isProcessing: backend.isProcessing,
            isCancelling: backend.isCancelling
        )
        guard !presentation.isPrimaryDisabled(hasSelectedSources: hasSelectedSources) else { return }

        if backend.isProcessing {
            cancelBatchSeparation()
        } else if !backend.isReady {
            Task {
                await backend.restartBackend()
            }
        } else {
            startBatchSeparation()
        }
    }

    private func cancelBatchSeparation() {
        batchProcessingTask?.cancel()
        Task {
            await backend.cancelCurrentOperation()
            await MainActor.run {
                batchProcessingTask = nil
            }
        }
    }

    private func upsertResultGroup(sourceURL: URL, summary: SeparationSummary) {
        // Attach per-stem run info so Results → Info shows this experiment's settings.
        let newFiles: [StemFile] = summary.files.map { file in
            var next = file
            if next.runInfo == nil {
                next.runInfo = StemRunInfo.from(summary: summary, stem: file.stem, path: file.path)
            }
            return next
        }

        if let index = resultGroups.firstIndex(where: { $0.sourceURL == sourceURL }) {
            var existingFiles = resultGroups[index].files
            for file in newFiles {
                if let existingIndex = existingFiles.firstIndex(where: { $0.path == file.path }) {
                    existingFiles[existingIndex] = file
                } else {
                    existingFiles.append(file)
                }
            }
            resultGroups[index].files = existingFiles.sorted(by: Self.stemSort)
            resultGroups[index].summary = summary
        } else {
            let group = BatchResultGroup(
                sourceURL: sourceURL,
                summary: summary,
                files: newFiles.sorted(by: Self.stemSort)
            )
            resultGroups.append(group)
        }
    }

    private static func stemSort(_ lhs: StemFile, _ rhs: StemFile) -> Bool {
        let leftBase = lhs.stem.replacingOccurrences(of: #"_\d+$"#, with: "", options: .regularExpression)
        let rightBase = rhs.stem.replacingOccurrences(of: #"_\d+$"#, with: "", options: .regularExpression)
        if leftBase != rightBase {
            return leftBase < rightBase
        }
        return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
    }

    private func prewarmResultPreviews(for stems: [StemFile]) {
        for stem in stems {
            Task {
                await analyzeResultStem(path: stem.path)
            }
        }
    }

    private func deleteStem(_ stem: StemFile) {
        do {
            if audioPreviewPlayer.playingPath == stem.path {
                audioPreviewPlayer.stop()
            }
            try BatchWorkspace.deleteStem(at: stem.path, from: &resultGroups)
            resultPreviewCache.remove(stem.path)
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

    private var usesPerSourcePresets: Bool {
        sources.count > 1
    }

    private var selectedStemsToCompare: [StemFile] {
        var result: [StemFile] = []
        for group in resultGroups {
            for stem in group.files {
                if selectedStemPaths.contains(stem.path) {
                    result.append(stem)
                }
            }
        }
        return result.sorted { $0.displayName < $1.displayName }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return isDirectory.boolValue
    }
}

private struct AppHeaderView: View {
    @ObservedObject var backend: BackendClient
    @Binding var modelPresetID: String
    @Binding var processPresetID: String
    let modelPresets: [SeparationPreset]
    let processPresets: [ProcessSettingsPreset]
    let renderEstimate: RenderEstimate?
    let hasSelectedSources: Bool
    let isSettingsSidebarOpen: Bool
    let primaryAction: () -> Void
    let settingsAction: () -> Void
    @Binding var modelRatings: [String: Int]
    @Binding var selectedModelIDs: Set<String>
    @State private var isModelPresetMenuOpen = false

    var body: some View {
        let presentation = ProcessingControlPresentation(
            isReady: backend.isReady,
            isProcessing: backend.isProcessing,
            isCancelling: backend.isCancelling
        )

        return HStack(spacing: 14) {
            AppLogoView()
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text("AuraSplitter")
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
            }
            .frame(width: 154, alignment: .leading)

            ModelPresetDropdown(
                selection: $modelPresetID,
                selectedIDs: $selectedModelIDs,
                isPresented: $isModelPresetMenuOpen,
                presets: modelPresets,
                models: backend.models,
                modelCache: backend.modelCache,
                modelRatings: $modelRatings,
                isDisabled: modelPresets.isEmpty || backend.isBusy
            )
            .frame(width: 188)

            Picker("Process Preset", selection: $processPresetID) {
                ForEach(processPresets) { preset in
                    Text(preset.title).tag(preset.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 144)
            .disabled(processPresets.isEmpty || backend.isBusy)
            .help("Process settings preset")

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(progressTitle)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let renderEstimate {
                        Text(renderEstimate.displayText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(renderEstimate.isCalibrated ? .green : .secondary)
                            .lineLimit(1)
                            .help(renderEstimate.detailText)
                    }
                    Text("\(Int(backend.progress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: backend.progress)
                    .tint(progressTint)
                if let renderEstimate {
                    Text(renderEstimate.detailText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 260, maxWidth: .infinity)

            Button(action: primaryAction) {
                Label(presentation.primaryTitle, systemImage: presentation.primarySystemImage)
                    .frame(width: 112)
            }
            .buttonStyle(.borderedProminent)
            .tint(presentation.isDestructive ? .red : .orange)
            .controlSize(.large)
            .disabled(presentation.isPrimaryDisabled(hasSelectedSources: hasSelectedSources))
            .help(primaryActionHelp)

            Button(action: settingsAction) {
                Image(systemName: "sidebar.trailing")
                    .symbolVariant(isSettingsSidebarOpen ? .fill : .none)
                    .frame(
                        width: WorkspaceLayoutMetrics.settingsToggleButtonSize,
                        height: WorkspaceLayoutMetrics.settingsToggleButtonSize
                    )
            }
            .buttonStyle(SettingsSidebarToggleButtonStyle(isActive: isSettingsSidebarOpen))
            .help(isSettingsSidebarOpen ? "Hide settings sidebar" : "Show settings sidebar")
            .accessibilityLabel(isSettingsSidebarOpen ? "Hide settings sidebar" : "Show settings sidebar")
        }
        .padding(.horizontal, 18)
        .background(.thinMaterial)
    }

    private var progressTitle: String {
        if backend.isBusy {
            return backend.currentStage
        }
        return backend.isReady ? "Idle" : "Backend not ready"
    }

    private var progressTint: Color {
        if backend.isCancelling {
            return .red
        }
        return backend.isProcessing ? .orange : .secondary
    }

    private var primaryActionHelp: String {
        if backend.isProcessing {
            return "Cancel the current separation"
        }
        if !backend.isReady {
            return "Restart backend"
        }
        return "Start selected separation"
    }

    private var statusText: String {
        if backend.isCancelling {
            return "Cancelling current process"
        }
        if backend.isProcessing {
            return "\(Int(backend.progress * 100))% - \(backend.currentStage)"
        }
        return backend.isReady ? "Ready" : "Starting backend"
    }

    private var statusColor: Color {
        if backend.isCancelling {
            return .red
        }
        if backend.isProcessing {
            return .orange
        }
        return backend.isReady ? .green : .orange
    }
}

private struct ModelPresetDropdown: View {
    @Binding var selection: String
    @Binding var selectedIDs: Set<String>
    @Binding var isPresented: Bool
    let presets: [SeparationPreset]
    let models: [SeparatorModel]
    let modelCache: ModelCache?
    @Binding var modelRatings: [String: Int]
    let isDisabled: Bool

    @State private var ratingFilter: Int = 0

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 8) {
                if selectedIDs.count > 1 {
                    Text("Multi (\(selectedIDs.count))")
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(selectedPreset?.title ?? "Model")
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    if let selectedPreset, let rating = modelRatings[selectedPreset.id], rating > 0 {
                        HStack(spacing: 1) {
                            ForEach(1...rating, id: \.self) { _ in
                                Image(systemName: "star.fill")
                                    .foregroundStyle(.orange)
                                    .font(.system(size: 9))
                            }
                        }
                    }
                    
                    ModelPresetStatusIndicators(state: selectedState)
                }
                
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .frame(height: 27)
            .contentShape(RoundedRectangle(cornerRadius: KSTheme.radiusSM, style: .continuous))
        }
        .buttonStyle(ModelPresetDropdownButtonStyle(isOpen: isPresented))
        .disabled(isDisabled)
        .help(selectedState.helpText)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("Filter:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $ratingFilter) {
                        Text("All").tag(0)
                        Text("★★★").tag(3)
                        Text("★★+").tag(2)
                        Text("★+").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 6)
                
                Divider()
                
                ScrollView {
                    let filteredPresets = presets.filter { preset in
                        let rating = modelRatings[preset.id] ?? 0
                        switch ratingFilter {
                        case 3: return rating == 3
                        case 2: return rating >= 2
                        case 1: return rating >= 1
                        default: return true
                        }
                    }
                    
                    if filteredPresets.isEmpty {
                        Text("No models match this filter")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 20)
                            .padding(.horizontal, 12)
                    } else {
                        LazyVStack(spacing: 2) {
                            ForEach(filteredPresets) { preset in
                                let state = ModelPresetMenuState(preset: preset, models: models, modelCache: modelCache)
                                ModelPresetDropdownRow(
                                    title: preset.title,
                                    state: state,
                                    isSelected: selectedIDs.contains(preset.id),
                                    rating: modelRatings[preset.id] ?? 0,
                                    onSelectName: {
                                        selectedIDs = [preset.id]
                                        selection = preset.id
                                        isPresented = false
                                    },
                                    onToggleCheckbox: {
                                        if selectedIDs.contains(preset.id) {
                                            if selectedIDs.count > 1 {
                                                selectedIDs.remove(preset.id)
                                                if selection == preset.id {
                                                    selection = selectedIDs.first ?? ""
                                                }
                                            }
                                        } else {
                                            selectedIDs.insert(preset.id)
                                            selection = preset.id
                                        }
                                    },
                                    onRatingChanged: { newRating in
                                        modelRatings[preset.id] = newRating
                                        UserDefaults.standard.set(modelRatings, forKey: "KirtanSplitter.modelRatings")
                                    }
                                )
                            }
                        }
                        .padding(6)
                    }
                }
                .frame(maxHeight: 520)
            }
            .frame(width: 320)
        }
        .accessibilityLabel("Model preset")
    }

    private var selectedPreset: SeparationPreset? {
        presets.first { $0.id == selection } ?? presets.first
    }

    private var selectedState: ModelPresetMenuState {
        guard let selectedPreset else {
            return ModelPresetMenuState.empty
        }
        return ModelPresetMenuState(preset: selectedPreset, models: models, modelCache: modelCache)
    }
}

private struct ModelPresetDropdownRow: View {
    let title: String
    let state: ModelPresetMenuState
    let isSelected: Bool
    let rating: Int
    let onSelectName: () -> Void
    let onToggleCheckbox: () -> Void
    let onRatingChanged: (Int) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggleCheckbox) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.body.weight(.medium))
                    .foregroundStyle(isSelected ? Color.orange : Color.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onSelectName) {
                Text(title)
                    .font(.callout)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            HStack(spacing: 2) {
                ForEach(1...3, id: \.self) { star in
                    Button {
                        onRatingChanged(rating == star ? 0 : star)
                    } label: {
                        Image(systemName: star <= rating ? "star.fill" : "star")
                            .foregroundStyle(star <= rating ? .orange : .secondary.opacity(0.4))
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.trailing, 4)

            ModelPresetStatusIndicators(state: state)
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: KSTheme.radiusSM, style: .continuous))
        .help(state.helpText)
    }
}

private struct ModelPresetStatusIndicators: View {
    let state: ModelPresetMenuState

    var body: some View {
        HStack(spacing: 6) {
            if state.isLocal {
                Circle()
                    .fill(Color.green)
                    .frame(
                        width: WorkspaceLayoutMetrics.modelPresetStatusDotSize,
                        height: WorkspaceLayoutMetrics.modelPresetStatusDotSize
                    )
                    .accessibilityLabel("Cached locally")
            }
            if let usageLabel = state.usageLabel {
                Text(usageLabel)
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Used \(state.usageCount) \(state.usageCount == 1 ? "time" : "times")")
            }
        }
    }
}

private struct ModelPresetDropdownButtonStyle: ButtonStyle {
    let isOpen: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.primary)
            .background(backgroundColor(isPressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: KSTheme.radiusSM, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: KSTheme.radiusSM, style: .continuous)
                    .stroke(isOpen ? Color.orange.opacity(0.65) : Color.secondary.opacity(0.22), lineWidth: 1)
            }
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if isPressed || isOpen {
            return Color.secondary.opacity(0.20)
        }
        return Color.secondary.opacity(0.13)
    }
}

private struct SettingsSidebarToggleButtonStyle: ButtonStyle {
    let isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(isActive ? Color.white : Color.primary)
            .background(backgroundColor(isPressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(isActive ? Color.orange.opacity(0.75) : Color.secondary.opacity(0.25), lineWidth: 1)
            }
            .shadow(color: isActive ? Color.orange.opacity(0.24) : Color.clear, radius: 8, y: 2)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.snappy(duration: 0.14), value: configuration.isPressed)
            .animation(.easeInOut(duration: 0.18), value: isActive)
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if isActive {
            return isPressed ? Color.orange.opacity(0.82) : Color.orange.opacity(0.70)
        }
        return isPressed ? Color.secondary.opacity(0.18) : Color.secondary.opacity(0.10)
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

private struct PreviewResizeHandle: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.secondary.opacity(0.08))
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.secondary.opacity(0.38))
                .frame(width: 42, height: 3)
        }
        .contentShape(Rectangle())
        .help("Resize audio preview")
    }
}
