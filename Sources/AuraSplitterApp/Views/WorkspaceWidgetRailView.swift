import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceWidgetRailView: View {
    @ObservedObject var backend: BackendClient
    let sources: [BatchSourceItem]
    @Binding var isDropTargeted: Bool
    let chooseFilesAction: ([URL]) -> Void
    let chooseFolderAction: (URL) -> Void
    /// One or more files/folders dropped from Finder.
    let droppedURLsAction: ([URL]) -> Void
    var automationAction: (() -> Void)? = nil

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                importWidget
                systemWidget
            }
            .padding(14)
        }
        .scrollIndicators(.automatic)
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

                Text(sources.isEmpty ? "Drop files or folders here" : currentSourceName)
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

                if let automationAction {
                    Button(action: automationAction) {
                        Label("Automation", systemImage: "gearshape.2.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(KSTheme.accent)
                    .controlSize(.large)
                    .disabled(backend.isBusy)
                    .help("Batch cut regions, multi-model stems, export Ready MIX")
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(dropBackground, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isDropTargeted ? Color.orange : Color.secondary.opacity(0.18),
                        style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: [5])
                    )
            }
            .contentShape(Rectangle())
            // Prefer dropDestination — more reliable for Finder file URLs on macOS than onDrop+Data cast.
            .dropDestination(for: URL.self, action: { urls, _ in
                guard !backend.isBusy, !urls.isEmpty else { return false }
                droppedURLsAction(urls)
                return true
            }, isTargeted: { targeted in
                isDropTargeted = targeted
            })
            // Fallback for providers that only expose UTType.fileURL as data.
            .onDrop(of: [.fileURL, .audio], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers)
            }
            .onTapGesture {
                if !backend.isBusy { pickInputFiles() }
            }
        }
    }

    private var systemWidget: some View {
        WidgetPanel(title: "System", systemImage: "gauge") {
            VStack(alignment: .leading, spacing: 8) {
                StatusLine(title: "Backend", value: backend.isReady ? "Ready" : "Starting", tint: backend.isReady ? .green : .orange)
                StatusLine(title: "Model", value: modelCacheStateText, tint: modelCacheTint)
                MiniGauge(title: "CPU", detail: cpuDetail, value: backend.runtimeStats?.cpu.systemPercent ?? 0, tint: .blue)
                // Backend process RSS only (GB numbers). Separate from whole-machine load.
                StatusLine(title: "Backend RAM", value: backendRamDetail, tint: .green)
                // Whole unified-memory load % (active+wired+compressed) — green bar.
                MiniGauge(
                    title: "System RAM",
                    detail: systemRamDetail,
                    value: backend.runtimeStats?.memory.usedPercent ?? 0,
                    tint: .green
                )
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

    private var modelCacheStateText: String {
        guard let hot = backend.runtimeStats?.modelHot else { return "waiting" }
        return hot ? "Hot" : "Cold"
    }

    private var modelCacheTint: Color {
        backend.runtimeStats?.modelHot == true ? .green : .secondary
    }

    private var cpuDetail: String {
        guard let cpu = backend.runtimeStats?.cpu else { return "waiting" }
        return "\(Int(cpu.systemPercent))% / \(cpu.coreCount)c"
    }

    /// Backend Python process RSS in GB (not system-wide load).
    private var backendRamDetail: String {
        guard let stats = backend.runtimeStats else { return "waiting" }
        let process = FileHelpers.formattedMemoryBytes(stats.process.rssBytes)
        let total = FileHelpers.formattedMemoryBytes(stats.memory.totalBytes)
        return "\(process) of \(total)"
    }

    /// Whole-machine unified memory: percent + used/total in Apple-style GB.
    private var systemRamDetail: String {
        guard let memory = backend.runtimeStats?.memory else { return "waiting" }
        let used = FileHelpers.formattedMemoryBytes(memory.usedBytes)
        let total = FileHelpers.formattedMemoryBytes(memory.totalBytes)
        return "\(Int(memory.usedPercent.rounded()))% · \(used) of \(total)"
    }

    private var gpuDetail: String {
        guard let gpu = backend.runtimeStats?.gpu else { return "waiting" }
        if let utilization = gpu.utilizationPercent {
            // Sensei-like: util% · GPU working-set memory (not "10 cores busy").
            if let bytes = gpu.inUseSystemMemoryBytes, bytes > 0 {
                return "\(Int(utilization))% · \(FileHelpers.formattedBytes(bytes))"
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
        guard !backend.isBusy else { return false }
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.audio.identifier)
        }
        guard !fileProviders.isEmpty else { return false }

        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []

        for provider in fileProviders {
            group.enter()
            // Try fileURL first (folders + any file), then generic loadObject(URL).
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    defer { group.leave() }
                    if let url = Self.url(fromDropItem: item) {
                        lock.lock()
                        urls.append(url)
                        lock.unlock()
                    }
                }
            } else {
                provider.loadObject(ofClass: URL.self) { object, _ in
                    defer { group.leave() }
                    if let url = object {
                        lock.lock()
                        urls.append(url)
                        lock.unlock()
                    }
                }
            }
        }

        group.notify(queue: .main) {
            guard !urls.isEmpty else { return }
            droppedURLsAction(urls)
        }
        return true
    }

    /// NSItemProvider may hand back URL, NSURL, Data (file URL bytes), or path String.
    private static func url(fromDropItem item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return url
        }
        if let url = item as? NSURL {
            return url as URL
        }
        if let data = item as? Data {
            if let url = URL(dataRepresentation: data, relativeTo: nil) {
                return url
            }
            if let path = String(data: data, encoding: .utf8) {
                let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("file:"), let url = URL(string: trimmed) {
                    return url
                }
                if !trimmed.isEmpty {
                    return URL(fileURLWithPath: trimmed)
                }
            }
        }
        if let path = item as? String, !path.isEmpty {
            if path.hasPrefix("file:"), let url = URL(string: path) {
                return url
            }
            return URL(fileURLWithPath: path)
        }
        return nil
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
