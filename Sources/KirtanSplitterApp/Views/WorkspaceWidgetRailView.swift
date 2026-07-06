import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceWidgetRailView: View {
    @ObservedObject var backend: BackendClient
    let sources: [BatchSourceItem]
    let isSettingsSidebarOpen: Bool
    @Binding var isDropTargeted: Bool
    let chooseFilesAction: ([URL]) -> Void
    let chooseFolderAction: (URL) -> Void
    let droppedURLAction: (URL) -> Void
    let startAction: () -> Void
    let settingsAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            importWidget
            processWidget
            systemWidget
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.thinMaterial)
    }

    private var header: some View {
        HStack(spacing: 8) {
            AppLogoView()
            VStack(alignment: .leading, spacing: 1) {
                Text("KirtanSplitter")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(backend.isReady ? "Ready" : "Starting")
                    .font(.caption2)
                    .foregroundStyle(backend.isReady ? .green : .orange)
            }
            Spacer(minLength: 4)
            Button(action: settingsAction) {
                Image(systemName: isSettingsSidebarOpen ? "sidebar.trailing" : "slider.horizontal.3")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.borderless)
            .help(isSettingsSidebarOpen ? "Hide settings" : "Show settings")
        }
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
                .disabled(backend.isProcessing)
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

    private var processWidget: some View {
        WidgetPanel(title: "Process", systemImage: "wand.and.stars") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(backend.isProcessing ? "Running" : "Idle")
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Text("\(Int(backend.progress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: backend.progress)
                    .tint(.orange)
                Button(action: startAction) {
                    HStack {
                        Image(systemName: backend.isProcessing ? "hourglass" : "play.fill")
                        Text(backend.isProcessing ? "Separating" : "Start")
                        Spacer()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.small)
                .disabled(!backend.isReady || !hasSelectedSources || backend.isProcessing)
            }
        }
    }

    private var systemWidget: some View {
        WidgetPanel(title: "System", systemImage: "gauge") {
            VStack(alignment: .leading, spacing: 8) {
                MiniGauge(title: "CPU", value: backend.runtimeStats?.cpu.systemPercent ?? 0, tint: .blue)
                MiniGauge(title: "GPU", value: backend.runtimeStats?.gpu.utilizationPercent ?? 0, tint: .orange)
                HStack {
                    Text("Models")
                    Spacer()
                    Text("\(modelCount)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
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
    let value: Double
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value, specifier: "%.0f")%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            ProgressView(value: min(100, max(0, value)), total: 100)
                .tint(tint)
        }
    }
}
