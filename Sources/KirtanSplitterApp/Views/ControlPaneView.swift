import AppKit
import SwiftUI

struct ControlPaneView: View {
    @ObservedObject var backend: BackendClient
    @ObservedObject var processPresetStore: ProcessSettingsPresetStore
    @ObservedObject var menuVisibility = MenuVisibilityStore.shared
    @Binding var settings: SeparationSettings
    @Binding var selectedProcessPresetID: String

    let applyProcessPresetAction: (String) -> Void

    @State private var newPresetName = ""
    @State private var advancedExpanded = false
    @State private var isModelPickerOpen = false
    @State private var isProcessPresetPickerOpen = false

    private let outputFormats = ["WAV", "FLAC"]
    private let speedModes = ["latency_safe_v3", "latency_safe", "default"]

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                modelSection
                Divider()
                processSection
                Divider()
                settingsPresetSection
            }
            .padding(18)
        }
        .background(.regularMaterial)
    }

    private var settingsPresetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Settings Presets")
                .font(.callout.weight(.semibold))

            // Compact dropdown: open rarely to toggle header eyes / pick a preset.
            Button {
                isProcessPresetPickerOpen.toggle()
            } label: {
                HStack(spacing: 4) {
                    Text(ProcessSettingsPreset.displayTitle(
                        for: selectedProcessPresetID,
                        in: processPresetStore.presets,
                        settings: settings
                    ))
                    .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(processPresetStore.presets.isEmpty || backend.isBusy)
            .accessibilityLabel("Settings Preset")
            .popover(isPresented: $isProcessPresetPickerOpen, arrowEdge: .bottom) {
                visibilityPickerPopover(
                    title: "Process presets",
                    help: "Eye = show in header. Click name to select (only visible). Fix applies when menu closes."
                ) {
                    ForEach(processPresetStore.presets) { preset in
                        let headerVisible = menuVisibility.isProcessPresetVisible(preset.id)
                        visibilityPickerRow(
                            title: preset.title,
                            isSelected: selectedProcessPresetID == preset.id,
                            isVisibleInHeader: headerVisible,
                            onToggleEye: {
                                // Only toggle visibility — do not jump selection mid-edit.
                                menuVisibility.toggleProcessPresetVisibility(preset.id)
                            },
                            onSelect: {
                                // Only header-visible presets can be chosen as the active preset.
                                guard menuVisibility.isProcessPresetVisible(preset.id) else { return }
                                selectedProcessPresetID = preset.id
                                isProcessPresetPickerOpen = false
                            }
                        )
                    }
                }
            }
            .onChange(of: isProcessPresetPickerOpen) { isOpen in
                // After finishing eye edits, drop a hidden active selection → Heavy-first.
                if !isOpen {
                    reselectVisibleProcessPresetIfNeeded()
                }
            }

            HStack(spacing: 8) {
                TextField("Preset name", text: $newPresetName)
                    .textFieldStyle(.roundedBorder)
                    .disabled(backend.isBusy)

                Button("Save", action: saveCurrentProcessPreset)
                    .disabled(backend.isBusy)
            }

            Button(role: .destructive, action: deleteSelectedProcessPreset) {
                Label("Delete Selected Preset", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(selectedProcessPreset?.isBuiltIn != false || backend.isBusy)
        }
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Model")
                .font(.callout.weight(.semibold))

            Button {
                isModelPickerOpen.toggle()
            } label: {
                HStack(spacing: 4) {
                    Text(selectedModelTitle)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(backend.presets.isEmpty || backend.isBusy)
            .accessibilityLabel("Model")
            .popover(isPresented: $isModelPickerOpen, arrowEdge: .bottom) {
                visibilityPickerPopover(
                    title: "Models",
                    help: "Eye = show in header. Click name to select (only visible). Fix applies when menu closes."
                ) {
                    ForEach(backend.presets) { preset in
                        let headerVisible = menuVisibility.isModelVisible(preset.id)
                        visibilityPickerRow(
                            title: preset.title,
                            isSelected: settings.presetID == preset.id,
                            isVisibleInHeader: headerVisible,
                            onToggleEye: {
                                // Only toggle visibility — do not jump selection mid-edit.
                                menuVisibility.toggleModelVisibility(preset.id)
                            },
                            onSelect: {
                                guard menuVisibility.isModelVisible(preset.id) else { return }
                                settings.presetID = preset.id
                                isModelPickerOpen = false
                            }
                        )
                    }
                }
            }
            .onChange(of: isModelPickerOpen) { isOpen in
                if !isOpen {
                    reselectVisibleModelIfNeeded()
                }
            }

            if let preset = backend.presets.first(where: { $0.id == settings.presetID }) {
                Text(preset.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                Image(systemName: selectedModelDownloaded ? "checkmark.circle.fill" : "arrow.down.circle")
                    .foregroundStyle(selectedModelDownloaded ? .green : .secondary)
                Text(selectedModelDownloaded ? "Model cached locally" : "Model downloads on first use")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let selectedModel {
                Text(selectedModel.filename)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    private var selectedModelTitle: String {
        backend.presets.first(where: { $0.id == settings.presetID })?.title ?? "Select model"
    }

    @ViewBuilder
    private func visibilityPickerPopover<Content: View>(
        title: String,
        help: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(help)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    content()
                }
            }
            .frame(maxHeight: 320)
        }
        .padding(12)
        .frame(width: 280)
    }

    private func visibilityPickerRow(
        title: String,
        isSelected: Bool,
        isVisibleInHeader: Bool,
        onToggleEye: @escaping () -> Void,
        onSelect: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Button(action: onToggleEye) {
                Image(systemName: isVisibleInHeader ? "eye" : "eye.slash")
                    .foregroundStyle(isVisibleInHeader ? Color.primary : Color.secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help(isVisibleInHeader ? "Hide from header menu" : "Show in header menu")

            Button(action: onSelect) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.callout)
                        .fontWeight(isSelected ? .semibold : .regular)
                        .foregroundStyle(isVisibleInHeader ? (isSelected ? .primary : .secondary) : .tertiary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isVisibleInHeader)
            .help(isVisibleInHeader ? "Select preset" : "Show in header (eye) before selecting")
        }
        .padding(.vertical, 3)
        .opacity(isVisibleInHeader ? 1 : 0.72)
    }

    private func reselectVisibleProcessPresetIfNeeded() {
        guard !menuVisibility.isProcessPresetVisible(selectedProcessPresetID) else { return }
        guard let nextID = ProcessSettingsPreset.preferredVisiblePresetID(
            in: processPresetStore.presets,
            isVisible: { menuVisibility.isProcessPresetVisible($0) },
            excluding: selectedProcessPresetID
        ) else { return }
        selectedProcessPresetID = nextID
    }

    private func reselectVisibleModelIfNeeded() {
        guard !menuVisibility.isModelVisible(settings.presetID) else { return }
        guard let nextID = menuVisibility.preferredVisibleModelID(
            in: backend.presets,
            excluding: settings.presetID
        ) else { return }
        settings.presetID = nextID
    }

    private var processSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Process Settings")
                .font(.callout.weight(.semibold))

            Picker("Format", selection: $settings.outputFormat) {
                ForEach(outputFormats, id: \.self) { format in
                    Text(format).tag(format)
                }
            }
            .pickerStyle(.segmented)
            .disabled(backend.isBusy)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Chunk")
                    Spacer()
                    Text(settings.chunkDuration == 0 ? "Off" : "\(Int(settings.chunkDuration))s")
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.chunkDuration, in: 0...90, step: 15)
                    .disabled(backend.isBusy)
            }

            Stepper(value: $settings.mdxcSegmentSize, in: 64...4096, step: 64) {
                HStack {
                    Text("Segment Size")
                    Spacer()
                    Text("\(settings.mdxcSegmentSize)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(backend.isBusy)
            .help("MDXC/RoFormer segment size passed to mlx-audio-separator.")

            Stepper(value: $settings.mdxcOverlap, in: 1...16, step: 1) {
                HStack {
                    Text("Overlap")
                    Spacer()
                    Text("\(settings.mdxcOverlap)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(backend.isBusy)

            Stepper(value: $settings.mdxcBatchSize, in: 1...4, step: 1) {
                HStack {
                    Text("Batch")
                    Spacer()
                    Text("\(settings.mdxcBatchSize)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(backend.isBusy)

            advancedDisclosure
        }
    }

    private var advancedDisclosure: some View {
        DisclosureGroup("Advanced", isExpanded: $advancedExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Speed", selection: $settings.speedMode) {
                    ForEach(speedModes, id: \.self) { mode in
                        Text(mode).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .disabled(backend.isBusy)
                .help("default leaves mlx-audio-separator settings unchanged; latency_safe uses conservative batch sizes; latency_safe_v3 also defers cache clearing and uses two write workers.")

                Toggle("Override Model Segment", isOn: $settings.mdxcOverrideModelSegmentSize)
                    .toggleStyle(.checkbox)
                    .disabled(backend.isBusy)
                if settings.effectiveMDXCOverrideModelSegmentSize && !settings.mdxcOverrideModelSegmentSize {
                    Text("Segment override will be enabled for this run.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Toggle("Keep Converted MLX Model", isOn: $settings.saveConvertedSafetensors)
                    .toggleStyle(.checkbox)
                    .disabled(backend.isBusy)
                    .help("Keeps converted safetensors so the model does not convert again on the next run.")
            }
            .padding(.top, 8)
        }
    }

    private var selectedProcessPreset: ProcessSettingsPreset? {
        processPresetStore.preset(id: selectedProcessPresetID)
    }

    private var selectedModelDownloaded: Bool {
        selectedModel?.isDownloaded ?? false
    }

    private var selectedModel: SeparatorModel? {
        guard let filename = selectedModelFilename else { return nil }
        return backend.models.first(where: { $0.filename == filename })
    }

    private var selectedModelFilename: String? {
        if let override = settings.modelOverride, !override.isEmpty {
            return override
        }
        return backend.presets.first(where: { $0.id == settings.presetID })?.modelFilename
    }

    private func saveCurrentProcessPreset() {
        let saved = processPresetStore.saveCustomPreset(named: newPresetName, settings: settings)
        selectedProcessPresetID = saved.id
        newPresetName = ""
    }

    private func deleteSelectedProcessPreset() {
        guard selectedProcessPreset?.isBuiltIn == false else { return }
        processPresetStore.deleteCustomPreset(id: selectedProcessPresetID)
        selectedProcessPresetID = ProcessSettingsPreset.defaultPresetID
        applyProcessPresetAction(selectedProcessPresetID)
    }
}

struct AppLogoView: View {
    var body: some View {
        Group {
            if let url = Bundle.main.url(forResource: "KirtanSplitter", withExtension: "svg"),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(.orange)
            }
        }
        .frame(width: 25, height: 25)
        .accessibilityHidden(true)
    }
}
