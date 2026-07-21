import Foundation
import Combine

/// Owns wizard navigation and the in-progress AutomationJob.
@MainActor
final class AutomationWizardStore: ObservableObject {
    @Published var step: AutomationWizardStep = .io
    @Published var job: AutomationJob
    @Published var runProgress = AutomationRunProgress()
    @Published var stepError: String?

    init(
        processPresetID: String = ProcessSettingsPreset.defaultPresetID,
        processSettings: SeparationSettings = SeparationSettings()
    ) {
        job = AutomationJob(
            sourceFolderPath: nil,
            outputFolderPath: nil,
            tracks: [],
            processPresetID: processPresetID,
            processSettings: ProcessSettingsSnapshot(settings: processSettings),
            regionEditorTrackID: nil
        )
    }

    // MARK: - Navigation

    var canGoBack: Bool {
        step != .io && runProgress.phase != .running
    }

    var canGoNext: Bool {
        guard runProgress.phase != .running else { return false }
        return validationMessage(for: step) == nil && step.next != nil
    }

    func goNext() {
        stepError = validationMessage(for: step)
        guard stepError == nil, let next = step.next else { return }
        if step == .io {
            ensureRegionEditorTrack()
            ensureDefaultOutputFolder()
        }
        step = next
        stepError = nil
    }

    func goBack() {
        guard canGoBack, let prev = step.previous else { return }
        step = prev
        stepError = nil
    }

    func validationMessage(for step: AutomationWizardStep) -> String? {
        switch step {
        case .io:
            if job.sourceFolderPath == nil { return "Choose a source folder." }
            if job.selectedTracks.isEmpty { return "Select at least one audio track." }
            if job.outputFolderPath == nil || job.outputFolderPath?.isEmpty == true {
                return "Choose an output folder (Ready MIX)."
            }
            return nil
        case .regions:
            return job.selectedTracks.isEmpty ? "No tracks selected." : nil
        case .matrix:
            let selected = job.selectedTracks
            if selected.isEmpty { return "No tracks selected." }
            if selected.contains(where: { $0.shortOutputName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                return "Every track needs a short output name."
            }
            if selected.allSatisfy({ !$0.hasAnyStemSelection() }) {
                return "Select at least one stem (model × role) to keep."
            }
            if selected.contains(where: { !$0.hasAnyStemSelection() }) {
                return "Each selected track needs at least one stem."
            }
            if job.outputFolderPath == nil || job.outputFolderPath?.isEmpty == true {
                return "Choose an output folder on Input/Output."
            }
            // Optional pipeline step 2
            if job.hasStep2 {
                // Every intermediate (selected or not) needs a final name for Ready MIX export.
                if job.step2Tracks.contains(where: {
                    $0.shortOutputName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }) {
                    return "Step 2: every intermediate needs a final name."
                }
                // Selected + stems → further split; deselected → passthrough as-is.
                // At least one Step-1 stem must exist (step2Tracks non-empty already).
                let further = job.step2Tracks.filter { $0.isSelected && $0.hasAnyStemSelection() }
                let passthrough = job.step2Tracks.filter { !($0.isSelected && $0.hasAnyStemSelection()) }
                if further.isEmpty && passthrough.isEmpty {
                    return "Step 2: no intermediate tracks."
                }
            }
            return nil
        }
    }

    // MARK: - Source folder

    func setSourceFolder(_ url: URL) {
        let files = BatchWorkspace.audioFiles(in: url)
        job.sourceFolderPath = url.path
        job.tracks = files.map { AutomationTrackPlan(sourceURL: $0) }
        job.outputFolderPath = AutomationJob.defaultOutputFolder(for: url).path
        job.regionEditorTrackID = job.tracks.first?.id
        clearMatrixStep2()
        stepError = nil
    }

    func setOutputFolder(_ url: URL) {
        job.outputFolderPath = url.path
        stepError = nil
    }

    func toggleTrackSelection(_ id: UUID) {
        guard let index = job.tracks.firstIndex(where: { $0.id == id }) else { return }
        job.tracks[index].isSelected.toggle()
    }

    func selectAllTracks(_ selected: Bool) {
        for index in job.tracks.indices {
            job.tracks[index].isSelected = selected
        }
    }

    func ensureDefaultOutputFolder() {
        guard job.outputFolderPath == nil || job.outputFolderPath?.isEmpty == true,
              let source = job.sourceFolderURL
        else { return }
        job.outputFolderPath = AutomationJob.defaultOutputFolder(for: source).path
    }

    func ensureRegionEditorTrack() {
        let selected = job.selectedTracks
        if let current = job.regionEditorTrackID,
           selected.contains(where: { $0.id == current }) {
            return
        }
        job.regionEditorTrackID = selected.first?.id
    }

    // MARK: - Zones

    /// Updates zones for `trackID` and **propagates to all selected tracks** by default.
    func updateZones(for trackID: UUID, zones: [AutomationTimeRange], propagateToAllSelected: Bool = true) {
        guard let index = job.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        let duration = job.tracks[index].durationSeconds
        let normalized = AutomationTimeRange.merge(
            zones.map { zone in
                if let duration { return zone.clamped(to: duration) }
                return zone
            }
        )
        if propagateToAllSelected {
            for i in job.tracks.indices where job.tracks[i].isSelected {
                let d = job.tracks[i].durationSeconds
                job.tracks[i].exclusionZones = normalized.map { z in
                    if let d { return z.clamped(to: d) }
                    return z
                }
            }
        } else {
            job.tracks[index].exclusionZones = normalized
        }
    }

    func clearZones(for trackID: UUID) {
        updateZones(for: trackID, zones: [], propagateToAllSelected: true)
    }

    // MARK: - Matrix (step 1)

    func setShortName(for trackID: UUID, name: String) {
        guard let index = job.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        job.tracks[index].shortOutputName = name
    }

    func toggleStem(trackID: UUID, modelID: String, stem: String) {
        guard let index = job.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        // Mutate a local copy then reassign so @Published always notifies (nested
        // dictionary/set edits can otherwise be silent and leave icons “dead”).
        var tracks = job.tracks
        var set = tracks[index].stemSelections[modelID] ?? []
        if set.contains(stem) {
            set.remove(stem)
        } else {
            set.insert(stem)
        }
        if set.isEmpty {
            tracks[index].stemSelections.removeValue(forKey: modelID)
        } else {
            tracks[index].stemSelections[modelID] = set
        }
        job.tracks = tracks
    }

    func isStemSelected(trackID: UUID, modelID: String, stem: String) -> Bool {
        job.tracks.first(where: { $0.id == trackID })?.stemSelections[modelID]?.contains(stem) == true
    }

    // MARK: - Matrix pipeline step 2 (max 2 steps)

    /// Create / rebuild step 2 from step-1 final names + selected stems.
    /// Left column becomes `MAIN_V(Vocal)`, `MAIN_V(Drum)`, … — only two steps total.
    func addMatrixStep() {
        stepError = validationMessageForAddingStep2()
        guard stepError == nil else { return }
        job.step2Tracks = AutomationJob.buildStep2Tracks(from: job.selectedTracks)
        guard !job.step2Tracks.isEmpty else {
            stepError = "Select stems in Step 1 first — they become Step 2 sources."
            return
        }
        job.matrixPipelineStep = 2
        stepError = nil
    }

    func removeMatrixStep() {
        clearMatrixStep2()
        stepError = nil
    }

    func setMatrixPipelineStep(_ step: Int) {
        guard step == 1 || (step == 2 && job.hasStep2) else { return }
        job.matrixPipelineStep = step
    }

    func clearMatrixStep2() {
        job.step2Tracks = []
        job.matrixPipelineStep = 1
    }

    func setStep2ShortName(for trackID: UUID, name: String) {
        guard let index = job.step2Tracks.firstIndex(where: { $0.id == trackID }) else { return }
        job.step2Tracks[index].shortOutputName = name
    }

    func toggleStep2TrackSelection(_ id: UUID) {
        guard let index = job.step2Tracks.firstIndex(where: { $0.id == id }) else { return }
        job.step2Tracks[index].isSelected.toggle()
    }

    func toggleStep2Stem(trackID: UUID, modelID: String, stem: String) {
        guard let index = job.step2Tracks.firstIndex(where: { $0.id == trackID }) else { return }
        var rows = job.step2Tracks
        var set = rows[index].stemSelections[modelID] ?? []
        if set.contains(stem) {
            set.remove(stem)
        } else {
            set.insert(stem)
        }
        if set.isEmpty {
            rows[index].stemSelections.removeValue(forKey: modelID)
        } else {
            rows[index].stemSelections[modelID] = set
        }
        job.step2Tracks = rows
    }

    func isStep2StemSelected(trackID: UUID, modelID: String, stem: String) -> Bool {
        job.step2Tracks.first(where: { $0.id == trackID })?.stemSelections[modelID]?.contains(stem) == true
    }

    private func validationMessageForAddingStep2() -> String? {
        let selected = job.selectedTracks
        if selected.isEmpty { return "Select tracks on Input/Output first." }
        if selected.contains(where: { $0.shortOutputName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return "Fill Final name on every track before Add Step."
        }
        if selected.allSatisfy({ !$0.hasAnyStemSelection() }) {
            return "Select stems in Step 1 — they become Step 2 sources."
        }
        return nil
    }

    /// Apply a process-settings preset (Fast / Max / custom…) to the automation job.
    func applyProcessPreset(_ preset: ProcessSettingsPreset) {
        job.processPresetID = preset.id
        job.processSettings = preset.snapshot
        stepError = nil
    }

    /// Current settings reconstructed from the job snapshot (for dirty-title checks).
    var processSettingsAsSeparation: SeparationSettings {
        var s = SeparationSettings()
        job.processSettings.apply(to: &s)
        return s
    }

    // MARK: - Process runner

    private var processTask: Task<Void, Never>?

    var isProcessing: Bool {
        runProgress.phase == .running
    }

    func startProcess(backend: BackendClient, processPresetStore: ProcessSettingsPresetStore) {
        guard !isProcessing else { return }
        if let msg = validationMessage(for: .matrix) {
            stepError = msg
            return
        }
        processTask?.cancel()
        processTask = Task { [weak self] in
            guard let self else { return }
            let runner = AutomationProcessRunner(backend: backend, processPresetStore: processPresetStore)
            do {
                try await runner.run(store: self)
            } catch is CancellationError {
                self.runProgress.phase = .cancelled
                self.runProgress.currentMessage = "Cancelled"
            } catch {
                if self.runProgress.phase == .running {
                    self.runProgress.phase = .failed
                    self.runProgress.currentMessage = error.localizedDescription
                }
                self.stepError = error.localizedDescription
            }
        }
    }

    func cancelProcess(backend: BackendClient) {
        processTask?.cancel()
        processTask = nil
        if runProgress.phase == .running {
            runProgress.phase = .cancelled
            runProgress.currentMessage = "Cancelling…"
        }
        Task {
            await backend.cancelCurrentOperation()
        }
    }
}
