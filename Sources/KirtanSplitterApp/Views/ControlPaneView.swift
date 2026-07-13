import AppKit
import SwiftUI

struct ControlPaneView: View {
    @ObservedObject var backend: BackendClient
    @ObservedObject var processPresetStore: ProcessSettingsPresetStore
    @Binding var settings: SeparationSettings
    @Binding var selectedProcessPresetID: String

    let applyProcessPresetAction: (String) -> Void

    @State private var newPresetName = ""

    private let outputFormats = ["WAV", "FLAC"]
    private let speedModes = ["latency_safe_v3", "latency_safe", "default"]

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                settingsPresetSection
                Divider()
                presetSection
                modelSection
                Divider()
                processSection
            }
            .padding(18)
        }
        .background(.regularMaterial)
    }

    private var settingsPresetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Settings Presets")
                .font(.callout.weight(.semibold))

            Menu {
                ForEach(processPresetStore.presets) { preset in
                    Button {
                        selectedProcessPresetID = preset.id
                    } label: {
                        Text(preset.title)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(ProcessSettingsPreset.displayTitle(
                        for: selectedProcessPresetID,
                        in: processPresetStore.presets,
                        settings: settings
                    ))
                    .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(processPresetStore.presets.isEmpty || backend.isBusy)
            .accessibilityLabel("Settings Preset")

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

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Model Preset")
                .font(.callout.weight(.semibold))

            Picker("Model Preset", selection: $settings.presetID) {
                ForEach(backend.presets) { preset in
                    Text(preset.title).tag(preset.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(backend.presets.isEmpty || backend.isBusy)

            if let preset = backend.presets.first(where: { $0.id == settings.presetID }) {
                Text(preset.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Model Override")
                .font(.callout.weight(.semibold))

            Picker("Model", selection: modelOverrideBinding) {
                Text("Use preset model").tag("")
                Divider()
                ForEach(backend.models) { model in
                    Text("\(model.pickerTitle) · \(model.type)").tag(model.filename)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(backend.models.isEmpty || backend.isBusy)

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

            Picker("Speed", selection: $settings.speedMode) {
                ForEach(speedModes, id: \.self) { mode in
                    Text(mode).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .disabled(backend.isBusy)
            .help("default leaves mlx-audio-separator settings unchanged; latency_safe uses conservative batch sizes; latency_safe_v3 also defers cache clearing and uses two write workers.")

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
    }

    private var modelOverrideBinding: Binding<String> {
        Binding(
            get: { settings.modelOverride ?? "" },
            set: { settings.modelOverride = $0.isEmpty ? nil : $0 }
        )
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
