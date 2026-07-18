import AppKit
import SwiftUI

/// Large multi-step Automation modal (source → regions → matrix → run).
struct AutomationWizardView: View {
    @ObservedObject var backend: BackendClient
    @StateObject private var store: AutomationWizardStore
    let onClose: () -> Void

    init(
        backend: BackendClient,
        processPresetID: String,
        processSettings: SeparationSettings,
        onClose: @escaping () -> Void
    ) {
        self.backend = backend
        _store = StateObject(
            wrappedValue: AutomationWizardStore(
                processPresetID: processPresetID,
                processSettings: processSettings
            )
        )
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            stepBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 920, minHeight: 620)
        .background(KSTheme.panelBackground)
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Automation")
                    .font(.title2.weight(.semibold))
                Text("Batch cut → multi-model stems → Ready MIX")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            stepIndicator
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var stepIndicator: some View {
        HStack(spacing: 8) {
            ForEach(AutomationWizardStep.allCases) { step in
                HStack(spacing: 6) {
                    Circle()
                        .fill(stepFill(step))
                        .frame(width: 8, height: 8)
                    Text(step.title)
                        .font(.caption.weight(store.step == step ? .semibold : .regular))
                        .foregroundStyle(store.step == step ? .primary : .secondary)
                }
                if step != .run {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func stepFill(_ step: AutomationWizardStep) -> Color {
        if step == store.step { return KSTheme.accent }
        if step < store.step { return KSTheme.accent.opacity(0.45) }
        return Color.secondary.opacity(0.35)
    }

    @ViewBuilder
    private var stepBody: some View {
        switch store.step {
        case .source:
            AutomationSourceStepView(store: store)
        case .regions:
            AutomationRegionsPlaceholderView(store: store, backend: backend)
        case .matrix:
            AutomationMatrixPlaceholderView(store: store, backend: backend)
        case .run:
            AutomationRunPlaceholderView(store: store)
        }
    }

    private var footer: some View {
        HStack {
            if let error = store.stepError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            Spacer()
            Button("Back") { store.goBack() }
                .disabled(!store.canGoBack)
            if store.step == .run {
                Button("Process") {
                    // Runner wired in A6
                    store.stepError = "Processing pipeline ships in the next automation steps."
                }
                .buttonStyle(.borderedProminent)
                .tint(KSTheme.accent)
                .disabled(store.validationMessage(for: .run) != nil || store.runProgress.phase == .running)
            } else {
                Button("Next") { store.goNext() }
                    .buttonStyle(.borderedProminent)
                    .tint(KSTheme.accent)
                    .disabled(!store.canGoNext)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

// MARK: - Step 1: Source

struct AutomationSourceStepView: View {
    @ObservedObject var store: AutomationWizardStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Source folder")
                .font(.headline)

            HStack(spacing: 10) {
                Text(store.job.sourceFolderPath ?? "No folder selected")
                    .font(.callout.monospaced())
                    .lineLimit(2)
                    .foregroundStyle(store.job.sourceFolderPath == nil ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

                Button("Choose…") { pickFolder() }
                    .buttonStyle(.bordered)
            }

            if !store.job.tracks.isEmpty {
                HStack {
                    Text("Tracks (\(store.job.selectedTracks.count)/\(store.job.tracks.count))")
                        .font(.headline)
                    Spacer()
                    Button("Select all") { store.selectAllTracks(true) }
                        .controlSize(.small)
                    Button("Select none") { store.selectAllTracks(false) }
                        .controlSize(.small)
                }

                List {
                    ForEach(store.job.tracks) { track in
                        HStack(spacing: 10) {
                            Image(systemName: track.isSelected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(track.isSelected ? KSTheme.accent : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.displayName)
                                    .font(.callout.weight(.medium))
                                Text(track.sourcePath)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { store.toggleTrackSelection(track.id) }
                    }
                }
                .listStyle(.inset)
            } else if store.job.sourceFolderPath != nil {
                Text("No supported audio files in this folder.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "folder.badge.gearshape")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("Choose a source folder")
                        .font(.headline)
                    Text("Pick a folder of long recordings. You’ll mark cut regions, pick stems per model, then export Ready MIX.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select the folder of source recordings"
        if panel.runModal() == .OK, let url = panel.url {
            store.setSourceFolder(url)
        }
    }
}

// MARK: - Placeholders (A2 / A5 / A6)

struct AutomationRegionsPlaceholderView: View {
    @ObservedObject var store: AutomationWizardStore
    @ObservedObject var backend: BackendClient

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cut regions")
                .font(.headline)
            Text("Mark semi-transparent red zones to remove (other singers, noise). Drag edges to fine-tune. Shift adds another zone. Full spectrogram editor ships next.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if store.job.selectedTracks.isEmpty {
                Text("No tracks selected.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Track", selection: Binding(
                    get: { store.job.regionEditorTrackID ?? store.job.selectedTracks.first?.id },
                    set: { store.job.regionEditorTrackID = $0 }
                )) {
                    ForEach(store.job.selectedTracks) { track in
                        Text(track.displayName).tag(Optional(track.id))
                    }
                }
                .labelsHidden()

                if let id = store.job.regionEditorTrackID,
                   let track = store.job.tracks.first(where: { $0.id == id }) {
                    Text("Zones on \(track.displayName): \(track.exclusionZones.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Add sample zone (0–10s)") {
                        var zones = track.exclusionZones
                        zones.append(AutomationTimeRange(start: 0, end: 10))
                        store.updateZones(for: id, zones: zones)
                    }
                    .controlSize(.small)
                    Button("Copy zones to all selected tracks") {
                        store.copyZonesToAllSelectedTracks(from: id)
                    }
                    .controlSize(.small)
                }
            }
            Spacer()
        }
        .padding(20)
    }
}

struct AutomationMatrixPlaceholderView: View {
    @ObservedObject var store: AutomationWizardStore
    @ObservedObject var backend: BackendClient

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Stem matrix")
                .font(.headline)
            Text("Rows = tracks, columns = models. Toggle stems from each model’s expected outputs. Short names feed Ready MIX. Full grid UI next.")
                .font(.callout)
                .foregroundStyle(.secondary)

            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(store.job.selectedTracks) { track in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(track.displayName)
                                    .font(.callout.weight(.semibold))
                                TextField(
                                    "Short name",
                                    text: Binding(
                                        get: { track.shortOutputName },
                                        set: { store.setShortName(for: track.id, name: $0) }
                                    )
                                )
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 200)
                            }
                            FlowStemPickers(
                                track: track,
                                models: backend.presets,
                                store: store
                            )
                        }
                        .padding(10)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
        .padding(20)
    }
}

private struct FlowStemPickers: View {
    let track: AutomationTrackPlan
    let models: [SeparationPreset]
    @ObservedObject var store: AutomationWizardStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(models) { model in
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        ForEach(model.expectedStems, id: \.self) { stem in
                            let on = store.isStemSelected(trackID: track.id, modelID: model.id, stem: stem)
                            Button {
                                store.toggleStem(trackID: track.id, modelID: model.id, stem: stem)
                            } label: {
                                Text(stem)
                                    .font(.caption2.weight(.medium))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(on ? KSTheme.accent.opacity(0.85) : Color.secondary.opacity(0.15), in: Capsule())
                                    .foregroundStyle(on ? Color.white : Color.primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

struct AutomationRunPlaceholderView: View {
    @ObservedObject var store: AutomationWizardStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Output")
                .font(.headline)

            HStack(spacing: 10) {
                Text(store.job.outputFolderPath ?? "No output folder")
                    .font(.callout.monospaced())
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                Button("Choose…") { pickOutput() }
                    .buttonStyle(.bordered)
            }

            let units = store.job.estimatedWorkUnitCount()
            Text("Selected tracks: \(store.job.selectedTracks.count) · Work units (prepare + separates): \(units)")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text("Process will: cut exclusion zones → run each selected model → keep only chosen stems → write short names into Ready MIX. Full runner in A6.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .padding(20)
    }

    private func pickOutput() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Select Ready MIX (or any output) folder"
        if panel.runModal() == .OK, let url = panel.url {
            store.job.outputFolderPath = url.path
        }
    }
}
