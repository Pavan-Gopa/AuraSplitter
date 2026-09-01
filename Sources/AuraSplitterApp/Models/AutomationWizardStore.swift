import Foundation
import Combine

/// Owns wizard navigation and the in-progress AutomationJob.
@MainActor
final class AutomationWizardStore: ObservableObject {
    @Published var step: AutomationWizardStep = .io
    @Published var job: AutomationJob
    @Published var runProgress = AutomationRunProgress()
    @Published var stepError: String?
    /// Expected roles supplied by the backend preset catalog. Until a catalog
    /// is registered, existing selections remain usable; a supplied catalog
    /// (including an empty one) is authoritative.
    private var expectedStemsByModelID: [String: Set<String>]?

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
            let selected = filteredTracks(
                job.selectedTracks,
                allowedByModel: expectedStemsByModelID
            )
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
                let catalogTracks = filteredTracks(
                    job.tracks,
                    allowedByModel: expectedStemsByModelID
                )
                let step2Tracks = filteredStep2Tracks(
                    job.step2Tracks,
                    tracks: catalogTracks,
                    allowedByModel: expectedStemsByModelID
                )
                // Every intermediate (selected or not) needs a final name for Ready MIX export.
                if step2Tracks.contains(where: {
                    $0.shortOutputName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }) {
                    return "Step 2: every intermediate needs a final name."
                }
                // Selected + stems → further split; deselected → passthrough as-is.
                // At least one Step-1 stem must exist (step2Tracks non-empty already).
                let further = step2Tracks.filter { $0.isSelected && $0.hasAnyStemSelection() }
                let passthrough = step2Tracks.filter { !($0.isSelected && $0.hasAnyStemSelection()) }
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
        var tracks = job.tracks
        tracks[index].isSelected.toggle()
        job.tracks = tracks
        pruneStep2Sources()
    }

    func selectAllTracks(_ selected: Bool) {
        var tracks = job.tracks
        for index in tracks.indices {
            tracks[index].isSelected = selected
        }
        job.tracks = tracks
        pruneStep2Sources()
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
        var tracks = job.tracks
        if propagateToAllSelected {
            for i in tracks.indices where tracks[i].isSelected {
                let d = tracks[i].durationSeconds
                tracks[i].exclusionZones = normalized.map { z in
                    if let d { return z.clamped(to: d) }
                    return z
                }
            }
        } else {
            tracks[index].exclusionZones = normalized
        }
        job.tracks = tracks
    }

    func clearZones(for trackID: UUID) {
        updateZones(for: trackID, zones: [], propagateToAllSelected: true)
    }

    // MARK: - Matrix (step 1)

    /// Register the backend's role contract and discard any stale selections.
    /// The UI calls this whenever the preset catalog is available so a
    /// model can never receive a role it does not produce.
    func configureMatrixPresets(_ presets: [SeparationPreset]) {
        var allowedByModel: [String: Set<String>] = [:]
        for preset in presets {
            allowedByModel[preset.id] = Set(preset.expectedStems)
        }
        expectedStemsByModelID = allowedByModel
        applyCatalogFiltering()
    }

    func setShortName(for trackID: UUID, name: String) {
        guard let index = job.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        var tracks = job.tracks
        tracks[index].shortOutputName = name
        job.tracks = tracks
        pruneStep2Sources()
    }

    func setSaveStep1Outputs(_ enabled: Bool) {
        guard job.hasStep2 else { return }
        var updatedJob = job
        updatedJob.saveStep1Outputs = enabled
        job = updatedJob
    }

    /// Returns only roles declared by the currently registered backend catalog.
    private func filteredSelections(
        _ selections: [String: Set<String>],
        allowedByModel: [String: Set<String>]?
    ) -> [String: Set<String>] {
        guard let allowedByModel else { return selections }
        return selections.reduce(into: [String: Set<String>]()) { result, entry in
            guard let allowed = allowedByModel[entry.key] else { return }
            let kept = entry.value.intersection(allowed)
            if !kept.isEmpty {
                result[entry.key] = kept
            }
        }
    }
    private func filteredTracks(
        _ tracks: [AutomationTrackPlan],
        allowedByModel: [String: Set<String>]?
    ) -> [AutomationTrackPlan] {
        tracks.map { track in
            var filtered = track
            filtered.stemSelections = filteredSelections(
                track.stemSelections,
                allowedByModel: allowedByModel
            )
            return filtered
        }
    }

    /// Step-2 rows are valid only while their selected Step-1 source remains
    /// selected and catalog-supported. This prevents persisted rows from
    /// becoming hidden inputs after a Step-1 toggle or catalog refresh.
    private func filteredStep2Tracks(
        _ rows: [AutomationStep2TrackPlan],
        tracks: [AutomationTrackPlan],
        allowedByModel: [String: Set<String>]?
    ) -> [AutomationStep2TrackPlan] {
        rows.compactMap { row in
            guard let parent = tracks.first(where: { $0.id == row.parentTrackID }),
                  parent.isSelected,
                  parent.stemSelections[row.fromModelID]?.contains(row.fromStem) == true
            else {
                return nil
            }
            var filtered = row
            filtered.stemSelections = filteredSelections(
                row.stemSelections,
                allowedByModel: allowedByModel
            )
            return filtered
        }
    }

    private func applyCatalogFiltering() {
        var updatedJob = job
        updatedJob.tracks = filteredTracks(
            job.tracks,
            allowedByModel: expectedStemsByModelID
        )
        if !job.step2Tracks.isEmpty {
            updatedJob.step2Tracks = AutomationJob.reconcileStep2Tracks(
                existing: job.step2Tracks,
                from: updatedJob.tracks,
                allowedStemsByModelID: expectedStemsByModelID
            )
        }
        if updatedJob.step2Tracks.isEmpty {
            updatedJob.matrixPipelineStep = 1
        }
        if updatedJob != job {
            job = updatedJob
        }
    }

    private func pruneStep2Sources() {
        guard !job.step2Tracks.isEmpty else { return }

        var updatedJob = job
        updatedJob.tracks = filteredTracks(
            job.tracks,
            allowedByModel: expectedStemsByModelID
        )
        updatedJob.step2Tracks = AutomationJob.reconcileStep2Tracks(
            existing: job.step2Tracks,
            from: updatedJob.tracks,
            allowedStemsByModelID: expectedStemsByModelID
        )
        if updatedJob.step2Tracks.isEmpty {
            updatedJob.matrixPipelineStep = 1
        }
        if updatedJob != job {
            job = updatedJob
        }
    }

    func toggleStem(trackID: UUID, modelID: String, stem: String) {
        if let allowedByModel = expectedStemsByModelID,
           allowedByModel[modelID]?.contains(stem) != true {
            return
        }
        guard let index = job.tracks.firstIndex(where: { $0.id == trackID }),
              job.tracks[index].isSelected
        else { return }
        // Mutate a local copy then reassign so @Published always notifies.
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
        pruneStep2Sources()
    }

    func isStemSelected(trackID: UUID, modelID: String, stem: String) -> Bool {
        job.tracks.first(where: { $0.id == trackID })?.stemSelections[modelID]?.contains(stem) == true
    }

    func addMatrixStep() {
        applyCatalogFiltering()
        stepError = validationMessageForAddingStep2()
        guard stepError == nil else { return }
        let rows = AutomationJob.reconcileStep2Tracks(
            existing: job.step2Tracks,
            from: job.selectedTracks,
            allowedStemsByModelID: expectedStemsByModelID
        )
        guard !rows.isEmpty else {
            stepError = "Select stems in Step 1 first — they become Step 2 sources."
            return
        }
        var updatedJob = job
        updatedJob.step2Tracks = rows
        updatedJob.matrixPipelineStep = 2
        job = updatedJob
        stepError = nil
    }

    func removeMatrixStep() {
        clearMatrixStep2()
        stepError = nil
    }

    func setMatrixPipelineStep(_ step: Int) {
        guard step == 1 || (step == 2 && job.hasStep2) else { return }
        var updatedJob = job
        updatedJob.matrixPipelineStep = step
        job = updatedJob
    }

    func clearMatrixStep2() {
        guard !job.step2Tracks.isEmpty || job.matrixPipelineStep != 1 else { return }
        var updatedJob = job
        updatedJob.step2Tracks = []
        updatedJob.matrixPipelineStep = 1
        job = updatedJob
    }

    func setStep2ShortName(for trackID: UUID, name: String) {
        guard let index = job.step2Tracks.firstIndex(where: { $0.id == trackID }) else { return }
        var rows = job.step2Tracks
        rows[index].shortOutputName = name
        job.step2Tracks = rows
    }

    func toggleStep2TrackSelection(_ id: UUID) {
        guard let index = job.step2Tracks.firstIndex(where: { $0.id == id }) else { return }
        var rows = job.step2Tracks
        rows[index].isSelected.toggle()
        job.step2Tracks = rows
    }

    func toggleStep2Stem(trackID: UUID, modelID: String, stem: String) {
        if let allowedByModel = expectedStemsByModelID,
           allowedByModel[modelID]?.contains(stem) != true {
            return
        }
        guard let index = job.step2Tracks.firstIndex(where: { $0.id == trackID }),
              job.step2Tracks[index].isSelected
        else { return }
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
        let selected = filteredTracks(
            job.selectedTracks,
            allowedByModel: expectedStemsByModelID
        )
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
        // Reconcile persisted selections with the backend catalog immediately
        // before validation and execution, even if the matrix view was skipped.
        configureMatrixPresets(backend.presets)
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
