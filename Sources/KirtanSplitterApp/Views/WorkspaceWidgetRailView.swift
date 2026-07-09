import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceWidgetRailView: View {
    @ObservedObject var backend: BackendClient
    let sources: [BatchSourceItem]
    @Binding var isDropTargeted: Bool
    let chooseFilesAction: ([URL]) -> Void
    let chooseFolderAction: (URL) -> Void
    let droppedURLAction: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            importWidget
            systemWidget
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.thinMaterial)
    }

    private var importWidget: some View {
        WidgetPanel(title: "Input", systemImage: "waveform") {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline) {
                    Text(sourceCountText)
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                    Spacer()
                    Text(selectedSourceText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Text(sources.isEmpty ? "Drop files here" : currentSourceName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 7) {
                    Button(action: pickInputFiles) {
                        Label("Files", systemImage: "doc.badge.plus")
                    }
                    Button(action: pickInputFolder) {
                        Label("Folder", systemImage: "folder")
                    }
                }
                .controlSize(.small)
                .disabled(backend.isBusy)
            }
            .padding(9)
            .background(dropBackground, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isDropTargeted ? Color.orange : Color.secondary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [5]))
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: pickInputFiles)
            .onDrop(of: [.fileURL, .audio], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers)
            }
        }
    }

    private var systemWidget: some View {
        WidgetPanel(title: "System", systemImage: "gauge") {
            VStack(alignment: .leading, spacing: 8) {
                StatusLine(title: "Backend", value: backend.isReady ? "Ready" : "Starting", tint: backend.isReady ? .green : .orange)
                MiniGauge(title: "CPU", detail: cpuDetail, value: backend.runtimeStats?.cpu.systemPercent ?? 0, tint: .blue)
                MiniGauge(title: "Memory", detail: memoryDetail, value: backend.runtimeStats?.memory.usedPercent ?? 0, tint: .purple)
                MiniGauge(title: "GPU", detail: gpuDetail, value: backend.runtimeStats?.gpu.utilizationPercent ?? 0, tint: .orange)
                StatusLine(title: "NPU", value: npuDetail, tint: npuTint)
                StatusLine(title: "Models", value: "\(modelCount)", tint: .secondary)
            }
        }
    }

    private var sourceCountText: String {
        sources.isEmpty ? "0" : "\(sources.count)"
    }

    private var selectedSourceText: String {
        let selected = sources.filter(\.isSelectedForProcessing).count
        return sources.isEmpty ? "batch" : "\(selected)/\(sources.count)"
    }

    private var currentSourceName: String {
        sources.first?.fileName ?? "No source"
    }

    private var hasSelectedSources: Bool {
        sources.contains { $0.isSelectedForProcessing }
    }

    private var modelCount: Int {
        backend.modelCache?.groups?.count ?? backend.runtimeStats?.modelCache?.groupCount ?? backend.models.count
    }

    private var cpuDetail: String {
        guard let cpu = backend.runtimeStats?.cpu else { return "waiting" }
        return "\(Int(cpu.systemPercent))% / \(cpu.coreCount)c"
    }

    private var memoryDetail: String {
        guard let memory = backend.runtimeStats?.memory else { return "waiting" }
        return "\(Int(memory.usedPercent))%"
    }

    private var gpuDetail: String {
        guard let gpu = backend.runtimeStats?.gpu else { return "waiting" }
        if let utilization = gpu.utilizationPercent {
            if let cores = gpu.gpuCoreCount {
                return "\(Int(utilization))% / \(cores)c"
            }
            return "\(Int(utilization))%"
        }
        return gpu.status
    }

    private var npuDetail: String {
        guard let coreML = backend.runtimeStats?.coreML else { return "waiting" }
        if coreML.neuralEngineAllowed {
            return coreML.computeUnits
        }
        return coreML.status
    }

    private var npuTint: Color {
        guard let coreML = backend.runtimeStats?.coreML else { return .secondary }
        return coreML.neuralEngineAllowed ? .green : .secondary
    }

    private var dropBackground: Color {
        if isDropTargeted {
            return .orange.opacity(0.10)
        }
        return .secondary.opacity(0.06)
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

private struct WidgetPanel<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            content
        }
        .padding(10)
        .background(.background.opacity(0.48), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct MiniGauge: View {
    let title: String
    let detail: String
    let value: Double
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(detail)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            ProgressView(value: min(100, max(0, value)), total: 100)
                .tint(tint)
        }
    }
}

private struct StatusLine: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .font(.caption)
    }
}
