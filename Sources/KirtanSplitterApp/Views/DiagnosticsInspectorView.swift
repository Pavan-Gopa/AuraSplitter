import SwiftUI

struct DiagnosticsInspectorView: View {
    @ObservedObject var backend: BackendClient
    let section: SettingsDrawerSection
    @State private var deletionCandidate: ModelCacheItem?
    @State private var sourceDeletionCandidate: ModelCacheGroup?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                sectionContent
            }
            .padding(16)
        }
        .background(.thinMaterial)
        .confirmationDialog(
            "Delete cached model file?",
            isPresented: deleteConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let item = deletionCandidate else { return }
                deletionCandidate = nil
                Task {
                    await backend.deleteModelCacheItem(item)
                }
            }
            Button("Cancel", role: .cancel) {
                deletionCandidate = nil
            }
        } message: {
            Text(deletionCandidate?.filename ?? "")
        }
        .confirmationDialog(
            "Delete source checkpoint?",
            isPresented: sourceDeleteConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button("Delete Source", role: .destructive) {
                guard let group = sourceDeletionCandidate else { return }
                sourceDeletionCandidate = nil
                Task {
                    await backend.deleteModelGroupSource(group)
                }
            }
            Button("Cancel", role: .cancel) {
                sourceDeletionCandidate = nil
            }
        } message: {
            Text("Keeps the converted MLX model and config. The large source checkpoint is replaced with a tiny placeholder so the backend will not download it again.")
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch section {
        case .process:
            EmptyView()
        case .models:
            modelStorageWidget
            modelCacheWidget
        case .run:
            metricsWidget
            jobWidget
            resourceWidget
            gpuWidget
        case .logs:
            logFileWidget
            logConsoleWidget
        }
    }

    private var jobWidget: some View {
        InspectorCard(title: "Process", systemImage: "waveform.path.ecg") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(backend.isProcessing ? "Running" : "Idle")
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Text("\(Int(backend.progress * 100))%")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: backend.progress)
                    .tint(.orange)
                Text(backend.currentStage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
    }

    private var resourceWidget: some View {
        InspectorCard(title: "System", systemImage: "cpu") {
            VStack(spacing: 12) {
                GaugeLine(
                    title: "CPU",
                    value: backend.runtimeStats?.cpu.systemPercent ?? 0,
                    detail: cpuDetail,
                    tint: .blue
                )
                GaugeLine(
                    title: "Memory",
                    value: backend.runtimeStats?.memory.usedPercent ?? 0,
                    detail: memoryDetail,
                    tint: .purple
                )
                GaugeLine(
                    title: "Backend RSS",
                    value: backendRSSPercent,
                    detail: backendRSSDetail,
                    tint: .green
                )
            }
        }
    }

    private var gpuWidget: some View {
        InspectorCard(title: "GPU", systemImage: "display") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(backend.runtimeStats?.gpu.device ?? "MLX device unknown")
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                }
                if let gpuDetail {
                    Text(gpuDetail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let utilization = backend.runtimeStats?.gpu.utilizationPercent {
                    GaugeLine(title: "Utilization", value: utilization, detail: String(format: "%.1f%%", utilization), tint: .orange)
                } else {
                    Text(backend.runtimeStats?.gpu.status ?? "GPU telemetry unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let power = backend.runtimeStats?.gpu.powerWatts {
                    Text("Power \(power, specifier: "%.2f") W")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var modelStorageWidget: some View {
        InspectorCard(title: "Storage", systemImage: "folder") {
            VStack(alignment: .leading, spacing: 10) {
                Text(modelStoragePath)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .textSelection(.enabled)

                HStack(spacing: 8) {
                    Button {
                        ModelStoragePaths.prepareModelDirectory(modelStoragePath)
                        FileHelpers.reveal(path: modelStoragePath)
                    } label: {
                        Label("Reveal", systemImage: "folder")
                    }
                    .controlSize(.small)

                    Button {
                        FileHelpers.copyPath(modelStoragePath)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var modelCacheWidget: some View {
        InspectorCard(title: "Models", systemImage: "externaldrive") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(modelCacheCountText)
                    Spacer()
                    Text(FileHelpers.formattedBytes(backend.modelCache?.totalBytes ?? backend.runtimeStats?.modelCache?.totalBytes ?? 0))
                        .foregroundStyle(.secondary)
                }
                .font(.caption)

                if !modelCacheGroups.isEmpty {
                    ForEach(modelCacheGroups) { group in
                        HStack(spacing: 8) {
                            Image(systemName: group.converted ? "checkmark.seal.fill" : "shippingbox")
                                .foregroundStyle(group.converted ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(group.displayName)
                                    .font(.caption2.weight(.semibold))
                                    .lineLimit(1)
                                if let technicalLine = modelGroupTechnicalLine(group) {
                                    Text(technicalLine)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                if let summary = group.summary, !summary.isEmpty {
                                    Text(summary)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Text(modelGroupDetail(group))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 4)
                            if group.canDeleteSource {
                                Button(role: .destructive) {
                                    sourceDeletionCandidate = group
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                                .foregroundStyle(.red)
                                .disabled(backend.isProcessing)
                                .help("Delete source checkpoint and keep converted MLX model")
                            }
                        }
                    }
                } else if legacyModelCacheItems.isEmpty {
                    Text("No cached models yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(legacyModelCacheItems.prefix(7))) { item in
                        HStack(spacing: 8) {
                            Image(systemName: item.kind == "converted" ? "checkmark.seal.fill" : "shippingbox")
                                .foregroundStyle(item.kind == "converted" ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.filename)
                                    .font(.caption2)
                                    .lineLimit(1)
                                Text("\(item.kind) · \(FileHelpers.formattedBytes(item.sizeBytes))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            Button(role: .destructive) {
                                deletionCandidate = item
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .foregroundStyle(.red)
                            .disabled(backend.isProcessing)
                            .help("Delete this cached model file from disk")
                        }
                    }
                }
            }
        }
    }

    private var logFileWidget: some View {
        InspectorCard(title: "Log File", systemImage: "doc.text") {
            VStack(alignment: .leading, spacing: 10) {
                Text(backend.backendLogPath ?? "Waiting for backend log path")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .textSelection(.enabled)

                HStack(spacing: 8) {
                    Button {
                        guard let path = backend.backendLogPath else { return }
                        FileHelpers.open(path: path)
                    } label: {
                        Label("Open", systemImage: "arrow.up.right.square")
                    }
                    .controlSize(.small)
                    .disabled(backend.backendLogPath == nil)

                    Button {
                        guard let path = backend.backendLogPath else { return }
                        FileHelpers.reveal(path: path)
                    } label: {
                        Label("Reveal", systemImage: "folder")
                    }
                    .controlSize(.small)
                    .disabled(backend.backendLogPath == nil)

                    Button {
                        FileHelpers.exportText(
                            logExportText,
                            suggestedFilename: "KirtanSplitter-backend.log"
                        )
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.down")
                    }
                    .controlSize(.small)
                    .disabled(logExportText.isEmpty)
                }
            }
        }
    }

    private var logConsoleWidget: some View {
        InspectorCard(title: "Backend Log", systemImage: "terminal") {
            ScrollView(.vertical, showsIndicators: true) {
                Text(logDisplayText)
                    .font(.caption2.monospaced())
                    .foregroundStyle(logExportText.isEmpty ? Color.secondary : Color.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .frame(minHeight: 300)
            .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.green.opacity(0.16), lineWidth: 1)
            }
        }
    }

    private var metricsWidget: some View {
        InspectorCard(title: "Last Run", systemImage: "timer") {
            VStack(alignment: .leading, spacing: 8) {
                if let summary = backend.lastSummary {
                    HStack {
                        Text(summary.model)
                            .lineLimit(1)
                        Spacer()
                        Text(FileHelpers.formattedDurationWithRawSeconds(summary.elapsedSeconds))
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)

                    if let settings = summary.settings {
                        Divider()
                        ForEach(settingRows(from: settings), id: \.0) { key, value in
                            HStack {
                                Text(key)
                                Spacer()
                                Text(value)
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption2.monospacedDigit())
                        }
                    }

                    if let metrics = summary.metrics, !metrics.isEmpty {
                        Divider()
                        ForEach(metricRows(from: metrics), id: \.0) { key, value in
                            HStack {
                                Text(key)
                                Spacer()
                                Text("\(value, specifier: "%.3f")s")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption2.monospacedDigit())
                        }
                    }
                } else {
                    Text("No completed run yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var cpuDetail: String {
        guard let cpu = backend.runtimeStats?.cpu else { return "waiting" }
        return "\(cpu.coreCount) cores · load \(String(format: "%.2f", cpu.loadAverage?.first ?? 0))"
    }

    private var memoryDetail: String {
        guard let memory = backend.runtimeStats?.memory else { return "waiting" }
        return "\(FileHelpers.formattedBytes(memory.usedBytes)) / \(FileHelpers.formattedBytes(memory.totalBytes))"
    }

    private var modelStoragePath: String {
        backend.modelCache?.modelDir
            ?? backend.runtimeStats?.modelCache?.modelDir
            ?? ModelStoragePaths.defaultModelDirectory()
    }

    private var logDisplayText: String {
        logExportText.isEmpty ? "Waiting for backend log entries." : logExportText
    }

    private var logExportText: String {
        let memoryLog = backend.backendLog.trimmingCharacters(in: .whitespacesAndNewlines)
        if !memoryLog.isEmpty {
            return memoryLog
        }
        guard let path = backend.backendLogPath else { return "" }
        return FileHelpers.readTrailingText(path: path, maxBytes: 120_000)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var backendRSSDetail: String {
        guard let process = backend.runtimeStats?.process else { return "waiting" }
        return "PID \(process.pid) · \(FileHelpers.formattedBytes(process.rssBytes)) · CPU \(String(format: "%.1f", process.cpuPercent))%"
    }

    private var backendRSSPercent: Double {
        guard
            let process = backend.runtimeStats?.process,
            let total = backend.runtimeStats?.memory.totalBytes,
            total > 0
        else { return 0 }
        return min(100, Double(process.rssBytes) / Double(total) * 100)
    }

    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(
            get: { deletionCandidate != nil },
            set: { isPresented in
                if !isPresented {
                    deletionCandidate = nil
                }
            }
        )
    }

    private var sourceDeleteConfirmationBinding: Binding<Bool> {
        Binding(
            get: { sourceDeletionCandidate != nil },
            set: { isPresented in
                if !isPresented {
                    sourceDeletionCandidate = nil
                }
            }
        )
    }

    private var modelCacheGroups: [ModelCacheGroup] {
        backend.modelCache?.groups ?? []
    }

    private var legacyModelCacheItems: [ModelCacheItem] {
        (backend.modelCache?.items ?? []).filter { $0.kind != "config" }
    }

    private var modelCacheCountText: String {
        if !modelCacheGroups.isEmpty {
            return "\(modelCacheGroups.count) models"
        }
        let count = backend.runtimeStats?.modelCache?.groupCount ?? legacyModelCacheItems.count
        return "\(count) models"
    }

    private func modelGroupDetail(_ group: ModelCacheGroup) -> String {
        var parts: [String] = []
        if group.converted {
            parts.append("converted \(FileHelpers.formattedBytes(group.convertedBytes))")
        } else if group.localState == "not_downloaded" {
            parts.append("not downloaded")
        } else if group.localState == "downloaded" {
            parts.append("downloaded")
        }
        if group.hasSource {
            parts.append("source \(FileHelpers.formattedBytes(group.sourceBytes))")
        } else if group.sourceRemoved {
            parts.append("source removed")
        }
        if group.configBytes > 0 {
            parts.append("config kept")
        }
        return parts.joined(separator: " · ")
    }

    private func modelGroupTechnicalLine(_ group: ModelCacheGroup) -> String? {
        let parts = [group.technicalName, group.architecture, group.backend]
            .compactMap { value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var gpuDetail: String? {
        guard let gpu = backend.runtimeStats?.gpu else { return nil }
        var parts: [String] = []
        if let count = gpu.gpuCoreCount {
            parts.append("\(count) GPU cores")
        }
        if let source = gpu.source {
            parts.append("telemetry \(source)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func settingRows(from settings: RunSettings) -> [(String, String)] {
        [
            ("segment", settings.mdxcSegmentSize.map(String.init) ?? "default"),
            ("overlap", settings.mdxcOverlap.map(String.init) ?? "default"),
            ("batch", settings.mdxcBatchSize.map(String.init) ?? "default"),
            ("override", settings.mdxcOverrideModelSegmentSize == true ? "on" : "off"),
            ("speed", settings.speedMode ?? "default"),
        ]
    }

    private func metricRows(from metrics: [String: Double]) -> [(String, Double)] {
        let order = ["decode_s", "preprocess_s", "inference_s", "postprocess_s", "write_s", "cleanup_s", "total_s"]
        return order.compactMap { key in
            guard let value = metrics[key] else { return nil }
            return (key.replacingOccurrences(of: "_s", with: ""), value)
        }
    }
}

private struct InspectorCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.callout.weight(.semibold))
                Spacer()
            }
            content
        }
        .padding(12)
        .background(.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct GaugeLine: View {
    let title: String
    let value: Double
    let detail: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value, specifier: "%.1f")%")
                    .foregroundStyle(.secondary)
            }
            .font(.caption.monospacedDigit())

            ProgressView(value: min(100, max(0, value)), total: 100)
                .tint(tint)

            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}
