import AppKit
import SwiftUI

/// Multi-step Automation: Input/Output → Regions → Matrix (+ Process).
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
        .frame(minWidth: 960, minHeight: 640)
        .background(KSTheme.panelBackground)
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Automation")
                    .font(.title2.weight(.semibold))
                Text("Input/Output → Regions → Matrix → Ready MIX")
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
        HStack(spacing: 10) {
            ForEach(AutomationWizardStep.allCases) { step in
                HStack(spacing: 5) {
                    Circle()
                        .fill(stepFill(step))
                        .frame(width: 8, height: 8)
                    Text(step.title)
                        .font(.caption.weight(store.step == step ? .semibold : .regular))
                        .foregroundStyle(store.step == step ? .primary : .secondary)
                }
                if step != .matrix {
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
        case .io:
            AutomationIOStepView(store: store)
        case .regions:
            AutomationRegionEditorView(store: store, backend: backend)
        case .matrix:
            AutomationMatrixStepView(store: store, backend: backend)
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
            if store.step == .matrix {
                Button("Process") {
                    store.stepError = "Processing pipeline ships next (cut → separate → Ready MIX)."
                }
                .buttonStyle(.borderedProminent)
                .tint(KSTheme.accent)
                .disabled(store.validationMessage(for: .matrix) != nil || store.runProgress.phase == .running)
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

// MARK: - Step 1: Input / Output

struct AutomationIOStepView: View {
    @ObservedObject var store: AutomationWizardStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Input
            VStack(alignment: .leading, spacing: 8) {
                Text("Input")
                    .font(.headline)
                HStack(spacing: 10) {
                    pathField(store.job.sourceFolderPath ?? "No source folder selected")
                    Button("Choose…") { pickSource() }
                        .buttonStyle(.bordered)
                }
            }

            // Output
            VStack(alignment: .leading, spacing: 8) {
                Text("Output (Ready MIX)")
                    .font(.headline)
                HStack(spacing: 10) {
                    pathField(store.job.outputFolderPath ?? "No output folder")
                    Button("Choose…") { pickOutput() }
                        .buttonStyle(.bordered)
                }
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
                            Text(track.displayName)
                                .font(.callout.weight(.medium))
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
                    Text("Choose source and Ready MIX folders")
                        .font(.headline)
                    Text("Then select which tracks to process. Regions and stem matrix come next.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
    }

    private func pathField(_ text: String) -> some View {
        Text(text)
            .font(.callout.monospaced())
            .lineLimit(2)
            .foregroundStyle(text.hasPrefix("No ") ? .secondary : .primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private func pickSource() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select the folder of source recordings"
        if panel.runModal() == .OK, let url = panel.url {
            store.setSourceFolder(url)
        }
    }

    private func pickOutput() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Select Ready MIX output folder"
        if panel.runModal() == .OK, let url = panel.url {
            store.setOutputFolder(url)
        }
    }
}

// MARK: - Matrix

struct AutomationMatrixStepView: View {
    @ObservedObject var store: AutomationWizardStore
    @ObservedObject var backend: BackendClient

    private let sourceW: CGFloat = 132
    private let finalW: CGFloat = 132
    private let modelW: CGFloat = 104
    private let rowH: CGFloat = 52

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Stem matrix")
                    .font(.headline)
                Spacer()
                Text("\(store.job.selectedTracks.count) tracks · \(store.job.estimatedWorkUnitCount()) jobs")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if store.job.selectedTracks.isEmpty {
                Text("No tracks selected.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                // One vertical scroll; middle scrolls horizontally. Thin separators.
                GeometryReader { geo in
                    VStack(spacing: 0) {
                        headerRow
                        ScrollView(.vertical, showsIndicators: false) {
                            LazyVStack(spacing: 0) {
                                ForEach(store.job.selectedTracks) { track in
                                    dataRow(track)
                                    Rectangle()
                                        .fill(Color.primary.opacity(0.08))
                                        .frame(height: 1)
                                }
                            }
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            }
        }
        .padding(14)
    }

    private var models: [SeparationPreset] { backend.presets }

    private var headerRow: some View {
        HStack(spacing: 0) {
            Text("Source")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: sourceW, alignment: .leading)
                .padding(.horizontal, 6)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                        if index > 0 {
                            Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 36)
                        }
                        Text(model.title)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .frame(width: modelW, height: 36)
                    }
                }
            }

            Text("Final name")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: finalW, alignment: .leading)
                .padding(.horizontal, 6)
        }
        .frame(height: 40)
        .background(Color.secondary.opacity(0.1))
    }

    private func dataRow(_ track: AutomationTrackPlan) -> some View {
        HStack(spacing: 0) {
            Text(track.displayName)
                .font(.caption.weight(.medium))
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(width: sourceW, alignment: .leading)
                .padding(.horizontal, 6)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                        if index > 0 {
                            Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1, height: rowH - 8)
                        }
                        LazyVGrid(
                            columns: [
                                GridItem(.fixed(28), spacing: 3),
                                GridItem(.fixed(28), spacing: 3),
                                GridItem(.fixed(28), spacing: 3),
                            ],
                            spacing: 3
                        ) {
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
                        .frame(width: modelW, height: rowH)
                    }
                }
            }

            TextField(
                "Main Vocal",
                text: Binding(
                    get: { track.shortOutputName },
                    set: { store.setShortName(for: track.id, name: $0) }
                )
            )
            .textFieldStyle(.roundedBorder)
            .font(.caption)
            .frame(width: finalW - 12)
            .padding(.horizontal, 6)
        }
        .frame(height: rowH)
    }
}

private struct StemRoleIconButton: View {
    let stem: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: StemRoleStyle.systemImage(for: stem))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isOn ? Color.white : StemRoleStyle.color(for: stem))
                .frame(width: 26, height: 26)
                .background(
                    Circle()
                        .fill(isOn ? StemRoleStyle.color(for: stem) : StemRoleStyle.color(for: stem).opacity(0.14))
                )
                .overlay(
                    Circle()
                        .strokeBorder(StemRoleStyle.color(for: stem).opacity(isOn ? 0 : 0.4), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(StemRoleStyle.accessibilityLabel(for: stem) + (isOn ? " · keep" : " · skip"))
    }
}
