import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ControlPaneView: View {
    @ObservedObject var backend: BackendClient
    @Binding var outputDirectory: URL?
    @Binding var settings: SeparationSettings
    @Binding var isDropTargeted: Bool

    let sources: [BatchSourceItem]
    let chooseFilesAction: ([URL]) -> Void
    let chooseFolderAction: (URL) -> Void
    let droppedURLAction: (URL) -> Void
    let startAction: () -> Void

    private let outputFormats = ["WAV", "FLAC"]
    private let speedModes = ["latency_safe_v3", "latency_safe", "default"]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            dropZone
            presetSection
            modelSection
            outputSection
            runSection
            Spacer(minLength: 0)
            statusSection
        }
        .padding(22)
        .background(.regularMaterial)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                AppLogoView()
                Text("KirtanSplitter")
                    .font(.title2.weight(.semibold))
                Spacer()
                Circle()
                    .fill(backend.isReady ? .green : .orange)
                    .frame(width: 9, height: 9)
            }
            Text("UVR models through MLX/Metal on Apple Silicon")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var dropZone: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isDropTargeted ? Color.orange : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: 2, dash: [7])
                )
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isDropTargeted ? Color.orange.opacity(0.08) : Color.clear)
                )
                .frame(height: 116)
                .overlay {
                    VStack(spacing: 8) {
                        Image(systemName: dropIconName)
                            .font(.system(size: 30))
                            .foregroundStyle(dropIconColor)
                        Text(dropTitle)
                            .font(.callout.weight(dropTitleWeight))
                            .lineLimit(1)
                        Text("WAV, FLAC, AIFF, M4A, MP3")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: pickInputFiles)
                .onDrop(of: [.fileURL, .audio], isTargeted: $isDropTargeted) { providers in
                    handleDrop(providers)
                }

            HStack(spacing: 8) {
                Button {
                    pickInputFolder()
                } label: {
                    Label("Choose Folder", systemImage: "folder")
                }
                .controlSize(.small)
                .disabled(backend.isProcessing)

                Spacer()

                Text(batchCountText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preset")
                .font(.callout.weight(.semibold))

            Picker("Preset", selection: $settings.presetID) {
                ForEach(backend.presets) { preset in
                    Text(preset.title).tag(preset.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(backend.presets.isEmpty || backend.isProcessing)

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
            Text("Model")
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
            .disabled(backend.models.isEmpty || backend.isProcessing)

            HStack(spacing: 6) {
                Image(systemName: selectedModelDownloaded ? "checkmark.circle.fill" : "arrow.down.circle")
                    .foregroundStyle(selectedModelDownloaded ? .green : .secondary)
                Text(selectedModelDownloaded ? "Model cached locally" : "Model downloads on first use")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let selectedModel = selectedModel {
                Text(selectedModel.filename)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Output")
                .font(.callout.weight(.semibold))

            HStack {
                Text(outputDirectory?.lastPathComponent ?? "Next to source")
                    .font(.callout)
                    .lineLimit(1)
                Spacer()
                Button("Choose", action: pickOutputDirectory)
                    .controlSize(.small)
            }

            Picker("Format", selection: $settings.outputFormat) {
                ForEach(outputFormats, id: \.self) { format in
                    Text(format).tag(format)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Chunk")
                    Spacer()
                    Text(settings.chunkDuration == 0 ? "Off" : "\(Int(settings.chunkDuration))s")
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.chunkDuration, in: 0...90, step: 15)
                    .disabled(backend.isProcessing)
            }

            Picker("Speed", selection: $settings.speedMode) {
                ForEach(speedModes, id: \.self) { mode in
                    Text(mode).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .disabled(backend.isProcessing)
            .help("default leaves mlx-audio-separator settings unchanged; latency_safe uses conservative batch sizes; latency_safe_v3 also defers cache clearing and uses two write workers.")

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("UVR Params")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Stepper(value: $settings.mdxcSegmentSize, in: 64...4096, step: 64) {
                    HStack {
                        Text("Segment Size")
                        Spacer()
                        Text("\(settings.mdxcSegmentSize)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .help("MDXC/RoFormer segment size passed to mlx-audio-separator. Values above the model default require Override Model Segment and use more memory.")

                Stepper(value: $settings.mdxcOverlap, in: 1...16, step: 1) {
                    HStack {
                        Text("Overlap")
                        Spacer()
                        Text("\(settings.mdxcOverlap)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .help("MDXC/RoFormer overlap between inference windows.")

                Stepper(value: $settings.mdxcBatchSize, in: 1...4, step: 1) {
                    HStack {
                        Text("Batch")
                        Spacer()
                        Text("\(settings.mdxcBatchSize)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .help("Higher batch values can be faster but use more memory.")

                Toggle("Override Model Segment", isOn: $settings.mdxcOverrideModelSegmentSize)
                    .toggleStyle(.checkbox)
                    .help("When off, models may keep their own embedded segment size.")
            }
            .disabled(backend.isProcessing)
        }
    }

    private var runSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: startAction) {
                HStack {
                    if backend.isProcessing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "wand.and.stars")
                    }
                    Text(backend.isProcessing ? "Separating..." : "Separate Selected")
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .controlSize(.large)
            .disabled(!backend.isReady || !hasSelectedSources || backend.isProcessing)

            if backend.isProcessing {
                ProgressView(value: backend.progress)
                    .tint(.orange)
                Text("\(Int(backend.progress * 100))% · \(backend.currentStage)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(backend.statusLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if !backend.backendLog.isEmpty {
                Text(backend.backendLog.split(separator: "\n").suffix(1).joined())
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
    }

    private var modelOverrideBinding: Binding<String> {
        Binding(
            get: { settings.modelOverride ?? "" },
            set: { settings.modelOverride = $0.isEmpty ? nil : $0 }
        )
    }

    private var dropIconName: String {
        sources.isEmpty ? "square.and.arrow.down" : "waveform"
    }

    private var dropIconColor: Color {
        sources.isEmpty ? .secondary : .orange
    }

    private var dropTitle: String {
        if sources.count == 1 {
            return sources[0].fileName
        }
        if !sources.isEmpty {
            return "\(sources.count) source files loaded"
        }
        return "Drop audio files or click to choose"
    }

    private var dropTitleWeight: Font.Weight {
        sources.isEmpty ? .regular : .semibold
    }

    private var batchCountText: String {
        guard !sources.isEmpty else { return "Batch ready" }
        let selectedCount = sources.filter(\.isSelectedForProcessing).count
        return "\(selectedCount)/\(sources.count) selected"
    }

    private var hasSelectedSources: Bool {
        sources.contains { $0.isSelectedForProcessing }
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

    private func pickInputFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            chooseFilesAction(panel.urls)
        }
    }

    private func pickInputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            chooseFolderAction(url)
        }
    }

    private func pickOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK {
            outputDirectory = panel.url
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                guard
                    let data = item as? Data,
                    let url = URL(dataRepresentation: data, relativeTo: nil)
                else { return }
                DispatchQueue.main.async {
                    droppedURLAction(url)
                }
            }
            return true
        }
        return false
    }
}

private struct AppLogoView: View {
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
