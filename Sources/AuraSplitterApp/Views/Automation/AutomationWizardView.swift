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

    private let sourceColumnWidth: CGFloat = 168
    private let finalColumnWidth: CGFloat = 168
    private let modelColumnMinWidth: CGFloat = 108

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Stem matrix")
                        .font(.headline)
                    Text("Icons match Results. Tap to keep. Left = source file · right = Ready MIX name.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if store.job.selectedTracks.isEmpty {
                Text("No tracks selected.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView([.horizontal, .vertical], showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        matrixHeaderRow
                        Divider().opacity(0.5)
                        ForEach(Array(store.job.selectedTracks.enumerated()), id: \.element.id) { index, track in
                            matrixDataRow(track)
                            if index < store.job.selectedTracks.count - 1 {
                                Divider().opacity(0.25)
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .padding(16)
    }

    private var models: [SeparationPreset] { backend.presets }

    private var matrixHeaderRow: some View {
        HStack(alignment: .bottom, spacing: 0) {
            Text("Source")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: sourceColumnWidth, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 8)

            ForEach(models) { model in
                Text(model.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(minWidth: modelColumnMinWidth, maxWidth: modelColumnMinWidth)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 8)
            }

            Text("Final name")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: finalColumnWidth, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
        }
        .background(Color.secondary.opacity(0.08))
    }

    private func matrixDataRow(_ track: AutomationTrackPlan) -> some View {
        HStack(alignment: .center, spacing: 0) {
            Text(track.displayName)
                .font(.callout.weight(.medium))
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(width: sourceColumnWidth, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
                .help(track.sourcePath)

            ForEach(models) { model in
                HStack(spacing: 4) {
                    ForEach(model.expectedStems, id: \.self) { stem in
                        StemRoleIconButton(
                            stem: stem,
                            isOn: store.isStemSelected(trackID: track.id, modelID: model.id, stem: stem),
                            action: {
                                store.toggleStem(trackID: track.id, modelID: model.id, stem: stem)
                            }
                        )
                    }
                }
                .frame(minWidth: modelColumnMinWidth, maxWidth: modelColumnMinWidth)
                .padding(.horizontal, 4)
                .padding(.vertical, 8)
            }

            TextField(
                "e.g. Main Vocal",
                text: Binding(
                    get: { track.shortOutputName },
                    set: { store.setShortName(for: track.id, name: $0) }
                )
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: finalColumnWidth - 16)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .background(Color.primary.opacity(0.02))
    }
}

/// Compact role icon toggle — same symbols/colors as Results stems.
private struct StemRoleIconButton: View {
    let stem: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: StemRoleStyle.systemImage(for: stem))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isOn ? Color.white : StemRoleStyle.color(for: stem))
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(isOn ? StemRoleStyle.color(for: stem) : StemRoleStyle.color(for: stem).opacity(0.14))
                )
                .overlay(
                    Circle()
                        .strokeBorder(
                            StemRoleStyle.color(for: stem).opacity(isOn ? 0 : 0.45),
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
        .help(StemRoleStyle.accessibilityLabel(for: stem) + (isOn ? " · keep" : " · skip"))
        .accessibilityLabel(StemRoleStyle.accessibilityLabel(for: stem))
        .accessibilityAddTraits(isOn ? .isSelected : [])
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
