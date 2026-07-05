import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ControlPaneView: View {
    @ObservedObject var backend: BackendClient
    @Binding var inputURL: URL?
    @Binding var outputDirectory: URL?
    @Binding var settings: SeparationSettings
    @Binding var isDropTargeted: Bool

    let startAction: () -> Void

    private let outputFormats = ["FLAC", "WAV"]
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
                Image(systemName: "waveform.badge.magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(.orange)
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
        RoundedRectangle(cornerRadius: 8)
            .strokeBorder(
                isDropTargeted ? Color.orange : Color.secondary.opacity(0.35),
                style: StrokeStyle(lineWidth: 2, dash: [7])
            )
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isDropTargeted ? Color.orange.opacity(0.08) : Color.clear)
            )
            .frame(height: 124)
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
            .onTapGesture(perform: pickInputFile)
            .onDrop(of: [.fileURL, .audio], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers)
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
                    Text("\(model.filename) · \(model.type)").tag(model.filename)
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
                    Text(backend.isProcessing ? "Separating..." : "Separate")
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .controlSize(.large)
            .disabled(!backend.isReady || inputURL == nil || backend.isProcessing)

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
        inputURL == nil ? "square.and.arrow.down" : "waveform"
    }

    private var dropIconColor: Color {
        inputURL == nil ? .secondary : .orange
    }

    private var dropTitle: String {
        inputURL?.lastPathComponent ?? "Drop an audio file"
    }

    private var dropTitleWeight: Font.Weight {
        inputURL == nil ? .regular : .semibold
    }

    private var selectedModelDownloaded: Bool {
        guard let model = backend.models.first(where: { $0.filename == (settings.modelOverride ?? "") }) else {
            return false
        }
        return model.isDownloaded
    }

    private func pickInputFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK {
            inputURL = panel.url
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
                    inputURL = url
                }
            }
            return true
        }
        return false
    }
}
