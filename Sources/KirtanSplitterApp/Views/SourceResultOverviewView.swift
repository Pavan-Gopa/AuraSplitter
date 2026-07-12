import SwiftUI

struct SourceResultOverviewView: View {
    @ObservedObject var backend: BackendClient
    @Binding var sources: [BatchSourceItem]
    let presets: [SeparationPreset]
    let usesPerSourcePresets: Bool
    let resultGroups: [BatchResultGroup]
    let previewSelection: AudioPreviewSelection
    let previewSourceAction: (BatchSourceItem) -> Void
    let previewStemAction: (StemFile) -> Void
    let deleteStemAction: (StemFile) -> Void
    @Binding var selectedStemPaths: Set<String>
    let compareAction: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            sourceColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            resultColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
    }

    private var sourceColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            columnHeader(title: "Source", systemImage: "waveform", detail: "\(selectedSourceCount)/\(sources.count) selected")

            if sources.isEmpty {
                emptyColumnText("Drop files or choose a folder.")
                Spacer(minLength: 0)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach($sources) { $source in
                            BatchSourceRow(
                                source: $source,
                                presets: presets,
                                usesPerSourcePresets: usesPerSourcePresets,
                                isActive: previewSelection == .source(source.id),
                                isDisabled: backend.isProcessing,
                                previewAction: { previewSourceAction(source) }
                            )
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(18)
    }

    private var resultColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            columnHeader(title: "Result", systemImage: "square.stack.3d.up", detail: resultDetail)

            if resultGroups.isEmpty {
                emptyColumnText(backend.isProcessing ? backend.currentStage : "Separated stems will appear here.")
                Spacer(minLength: 0)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(resultGroups) { group in
                            ResultGroupView(
                                group: group,
                                previewSelection: previewSelection,
                                previewStemAction: previewStemAction,
                                deleteStemAction: deleteStemAction,
                                selectedStemPaths: $selectedStemPaths,
                                compareAction: compareAction
                            )
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(18)
    }

    private var selectedSourceCount: Int {
        sources.filter(\.isSelectedForProcessing).count
    }

    private var resultDetail: String {
        let fileCount = resultGroups.reduce(0) { $0 + $1.files.count }
        if resultGroups.isEmpty {
            return backend.models.isEmpty ? "Loading model catalog" : "\(backend.models.count) MLX models"
        }
        return "\(resultGroups.count) sources · \(fileCount) stems"
    }

    private func columnHeader(title: String, systemImage: String, detail: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Spacer()
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func emptyColumnText(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct BatchSourceRow: View {
    @Binding var source: BatchSourceItem
    let presets: [SeparationPreset]
    let usesPerSourcePresets: Bool
    let isActive: Bool
    let isDisabled: Bool
    let previewAction: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: $source.isSelectedForProcessing)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(isDisabled)

            Button(action: previewAction) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text(source.fileName)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        if source.isAnalyzing {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                    if let analysis = source.analysis {
                        SourceMetricRow(analysis: analysis)
                    } else if let analysisError = source.analysisError {
                        Label(analysisError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    } else {
                        Text(source.url.deletingLastPathComponent().path)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if usesPerSourcePresets {
                Picker("Preset", selection: $source.presetID) {
                    ForEach(presets) { preset in
                        Text(preset.title).tag(preset.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 170)
                .disabled(presets.isEmpty || isDisabled)
            } else {
                Label("Global", systemImage: "slider.horizontal.3")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: KSTheme.radiusSM))
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .background(isActive ? Color.orange.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: KSTheme.radiusSM))
    }
}

private struct SourceMetricRow: View {
    let analysis: AudioAnalysis

    var body: some View {
        HStack(spacing: 6) {
            metric(analysis.channelLabel, systemImage: analysis.channels == 1 ? "circle.lefthalf.filled" : "circle.grid.cross")
            metric(FileHelpers.formattedDuration(analysis.durationSeconds), systemImage: "timer")
            metric("\(analysis.sampleRate) Hz", systemImage: "dot.radiowaves.left.and.right")
            if let bitDepthLabel = analysis.bitDepthLabel {
                metric(bitDepthLabel, systemImage: "waveform")
            }
            if let modelLabel = analysis.separationModelLabel {
                metric(modelLabel, systemImage: "cpu", monospaced: false)
            }
            metric(analysis.peakLabel, systemImage: "meter.waveform", warning: analysis.clipped || analysis.peakDb >= -0.25)
        }
    }

    private func metric(_ text: String, systemImage: String, warning: Bool = false, monospaced: Bool = true) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(text)
                .font(monospaced ? .caption2.monospacedDigit() : .caption2)
                .lineLimit(1)
        }
        .font(.caption2)
        .foregroundStyle(warning ? .red : .secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background((warning ? Color.red : Color.secondary).opacity(0.10), in: RoundedRectangle(cornerRadius: 5))
    }
}

private struct ResultGroupView: View {
    let group: BatchResultGroup
    let previewSelection: AudioPreviewSelection
    let previewStemAction: (StemFile) -> Void
    let deleteStemAction: (StemFile) -> Void
    @Binding var selectedStemPaths: Set<String>
    let compareAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.sourceName)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let summary = group.summary {
                        Text("\(summary.model) · \(FileHelpers.formattedDurationWithRawSeconds(summary.elapsedSeconds))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Text("\(group.files.count) stems")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            LazyVStack(spacing: 0) {
                ForEach(group.files) { stem in
                    ResultStemRow(
                        stem: stem,
                        isActive: previewSelection == .result(stem.path),
                        selectedStemPaths: $selectedStemPaths,
                        compareAction: compareAction,
                        previewAction: { previewStemAction(stem) },
                        deleteAction: { deleteStemAction(stem) }
                    )
                }
            }
        }
        .padding(.vertical, 12)
    }
}

private struct ResultStemRow: View {
    let stem: StemFile
    let isActive: Bool
    @Binding var selectedStemPaths: Set<String>
    let compareAction: () -> Void
    let previewAction: () -> Void
    let deleteAction: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: isSelectedBinding)
                .toggleStyle(.checkbox)
                .labelsHidden()

            Button(action: previewAction) {
                HStack(spacing: 10) {
                    Image(systemName: stemIconName)
                        .foregroundStyle(stemColor)
                        .frame(width: 22)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(stem.displayName)
                            .font(.callout.weight(.medium))
                        HStack(spacing: 8) {
                            Text(stem.fileName)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(FileHelpers.formattedBytes(stem.sizeBytes))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                FileHelpers.reveal(path: stem.path)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")

            Button(role: .destructive, action: deleteAction) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .help("Delete stem file")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(isActive ? Color.orange.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: KSTheme.radiusSM))
        .contextMenu {
            if selectedStemPaths.count >= 2 {
                Button(action: compareAction) {
                    Label("Compare Selected (\(selectedStemPaths.count))", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                }
            } else {
                Button(action: compareAction) {
                    Label("Compare Selected (Select 2+ stems)", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                }
                .disabled(true)
            }
        }
    }

    private var isSelectedBinding: Binding<Bool> {
        Binding(
            get: { selectedStemPaths.contains(stem.path) },
            set: { isSelected in
                if isSelected {
                    selectedStemPaths.insert(stem.path)
                } else {
                    selectedStemPaths.remove(stem.path)
                }
            }
        )
    }

    private var stemIconName: String {
        switch stem.stem {
        case "vocals", "lead_vocals": return "mic.fill"
        case "drums", "kick", "snare", "toms": return "music.quarternote.3"
        case "bass": return "waveform.path.badge.minus"
        case "piano": return "pianokeys"
        case "guitar": return "guitars"
        default: return "waveform"
        }
    }

    private var stemColor: Color {
        switch stem.stem {
        case "vocals", "lead_vocals": return .orange
        case "drums", "kick", "snare", "toms": return .red
        case "bass": return .purple
        case "piano": return .green
        case "guitar": return .cyan
        default: return .blue
        }
    }
}
