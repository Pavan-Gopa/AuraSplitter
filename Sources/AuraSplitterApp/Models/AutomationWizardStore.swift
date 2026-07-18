import Foundation
import Combine

/// Owns wizard navigation and the in-progress AutomationJob.
@MainActor
final class AutomationWizardStore: ObservableObject {
    @Published var step: AutomationWizardStep = .source
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
        step != .source && runProgress.phase != .running
    }

    var canGoNext: Bool {
        guard runProgress.phase != .running else { return false }
        return validationMessage(for: step) == nil && step.next != nil
    }

    func goNext() {
        stepError = validationMessage(for: step)
        guard stepError == nil, let next = step.next else { return }
        if step == .source {
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
        case .source:
            if job.sourceFolderPath == nil { return "Choose a source folder." }
            if job.selectedTracks.isEmpty { return "Select at least one audio track." }
            return nil
        case .regions:
            // Zones optional — empty means use full track.
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
            return nil
        case .run:
            guard let out = job.outputFolderPath, !out.isEmpty else {
                return "Choose an output folder (e.g. Ready MIX)."
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

    func updateZones(for trackID: UUID, zones: [AutomationTimeRange]) {
        guard let index = job.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        let duration = job.tracks[index].durationSeconds
        let normalized = zones.map { zone -> AutomationTimeRange in
            if let duration { return zone.clamped(to: duration) }
            return zone
        }
        job.tracks[index].exclusionZones = AutomationTimeRange.merge(normalized)
    }

    func copyZonesToAllSelectedTracks(from trackID: UUID) {
        guard let source = job.tracks.first(where: { $0.id == trackID }) else { return }
        let zones = source.exclusionZones
        for index in job.tracks.indices where job.tracks[index].isSelected {
            job.tracks[index].exclusionZones = zones
        }
    }

    // MARK: - Matrix

    func setShortName(for trackID: UUID, name: String) {
        guard let index = job.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        job.tracks[index].shortOutputName = name
    }

    func toggleStem(trackID: UUID, modelID: String, stem: String) {
        guard let index = job.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        var set = job.tracks[index].stemSelections[modelID] ?? []
        if set.contains(stem) {
            set.remove(stem)
        } else {
            set.insert(stem)
        }
        if set.isEmpty {
            job.tracks[index].stemSelections.removeValue(forKey: modelID)
        } else {
            job.tracks[index].stemSelections[modelID] = set
        }
    }

    func isStemSelected(trackID: UUID, modelID: String, stem: String) -> Bool {
        job.tracks.first(where: { $0.id == trackID })?.stemSelections[modelID]?.contains(stem) == true
    }
}
