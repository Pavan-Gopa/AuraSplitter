import Foundation
import SwiftUI

@MainActor
final class PreviewStore: ObservableObject {
    @Published var selection: AudioPreviewSelection = .none
    @Published var analysis: AudioAnalysis?
    @Published var analysisError: String?
    @Published var isAnalyzing = false
    @Published var resultCache = AudioPreviewAnalysisCache()
    @Published var layerSettings = AudioPreviewLayerSettings()
    @Published var heightFraction = AudioPreviewLayout.defaultBottomFraction
    @Published var isFullscreen = false

    var resizeStartFraction: CGFloat?

    private let backend: BackendClient
    private let player: AudioPreviewPlayer

    init(backend: BackendClient, player: AudioPreviewPlayer) {
        self.backend = backend
        self.player = player
    }

    func previewSource(_ source: BatchSourceItem, sources: [BatchSourceItem]) {
        let path = source.url.path
        let previousTime = player.currentTime

        selection = .source(source.id)
        analysis = source.analysis
        analysisError = source.analysisError
        isAnalyzing = source.isAnalyzing

        player.seek(path: path, time: previousTime)

        if source.analysis == nil, source.analysisError == nil {
            Task {
                await analyzeSource(id: source.id, sources: sources)
            }
        }
    }

    func previewStem(_ stem: StemFile) {
        let path = stem.path
        let previousTime = player.currentTime

        let sel = AudioPreviewSelection.result(path)
        selection = sel
        analysis = nil
        analysisError = nil
        isAnalyzing = false

        player.seek(path: path, time: previousTime)

        if applyCachedResultPreview(for: path) {
            return
        }

        Task {
            await analyzeResultStem(path: path)
        }
    }

    func analyzeSource(id: String, sources: [BatchSourceItem]) async {
        guard let source = sources.first(where: { $0.id == id }) else { return }
        let url = source.url

        if let cached = await PreviewAnalysisDiskCache.shared.loadAsync(path: url.path) {
            if selection == .source(id) {
                analysis = cached
                analysisError = nil
                isAnalyzing = false
            }
            return
        }

        if selection == .source(id) {
            isAnalyzing = true
            analysisError = nil
        }

        do {
            let result = try await backend.analyzeAudio(url: url)
            await PreviewAnalysisDiskCache.shared.storeAsync(result)
            if selection == .source(id) {
                analysis = result
                analysisError = nil
                isAnalyzing = false
            }
        } catch {
            if selection == .source(id) {
                analysisError = error.localizedDescription
                isAnalyzing = false
            }
        }
    }

    @discardableResult
    func applyCachedResultPreview(for path: String) -> Bool {
        if let cached = resultCache.analysis(for: path) {
            analysis = cached
            analysisError = nil
            isAnalyzing = false
            return true
        }
        if let error = resultCache.error(for: path) {
            analysis = nil
            analysisError = error
            isAnalyzing = false
            return true
        }
        if resultCache.isAnalyzing(path) {
            analysis = nil
            analysisError = nil
            isAnalyzing = true
            return true
        }
        return false
    }

    func analyzeResultStem(path: String) async {
        let sel = AudioPreviewSelection.result(path)
        guard resultCache.shouldStartAnalysis(for: path) else {
            if selection == sel {
                applyCachedResultPreview(for: path)
            }
            return
        }

        if selection == sel {
            analysis = nil
            analysisError = nil
            isAnalyzing = true
        }

        do {
            let url = URL(fileURLWithPath: path)
            let result = try await backend.analyzeAudio(url: url)
            guard FileManager.default.fileExists(atPath: path) else {
                resultCache.remove(path)
                if selection == sel {
                    selection = .none
                    analysis = nil
                    analysisError = nil
                    isAnalyzing = false
                }
                return
            }
            resultCache.store(result, for: path)
            guard selection == sel else { return }
            analysis = result
            analysisError = nil
            isAnalyzing = false
        } catch {
            if !FileManager.default.fileExists(atPath: path) {
                resultCache.remove(path)
                if selection == sel {
                    selection = .none
                    analysis = nil
                    analysisError = nil
                    isAnalyzing = false
                }
                return
            }
            resultCache.storeError(error.localizedDescription, for: path)
            guard selection == sel else { return }
            analysis = nil
            analysisError = error.localizedDescription
            isAnalyzing = false
        }
    }

    func prewarmResultPreviews(for stems: [StemFile]) {
        for stem in stems {
            Task {
                await analyzeResultStem(path: stem.path)
            }
        }
    }

    func clearPreview() {
        selection = .none
        analysis = nil
        analysisError = nil
        isAnalyzing = false
    }

    func removeStemPreview(_ path: String) {
        resultCache.remove(path)
        if selection == .result(path) {
            clearPreview()
        }
    }
}
