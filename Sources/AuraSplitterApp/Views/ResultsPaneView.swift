import SwiftUI

struct ResultsPaneView: View {
    @ObservedObject var backend: BackendClient

    let results: [StemFile]
    let summary: SeparationSummary?
    @ObservedObject var previewPlayer: StemPreviewPlayer

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if results.isEmpty {
                emptyState
            } else {
                resultList
            }

            if !backend.backendLog.isEmpty {
                Divider()
                logView
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Stems")
                    .font(.headline)
                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if let first = results.first {
                Button {
                    FileHelpers.reveal(path: first.path)
                } label: {
                    Label("Reveal", systemImage: "folder")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "music.note.list")
                .font(.system(size: 56))
                .foregroundStyle(.secondary.opacity(0.45))
            Text(backend.isReady ? "Drop a recording and start separation" : "Starting MLX backend")
                .font(.title3.weight(.medium))
            Text(backend.isReady ? "First run downloads the selected model into the local models folder." : backend.currentStage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var resultList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(results) { stem in
                    StemRowView(
                        stem: stem,
                        isPlaying: previewPlayer.playingPath == stem.path,
                        playAction: { previewPlayer.toggle(path: stem.path) }
                    )
                    Divider()
                        .padding(.leading, 68)
                }
            }
        }
    }

    private var logView: some View {
        ScrollView {
            Text(backend.backendLog)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(12)
        }
        .frame(height: 130)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.8))
    }

    private var summaryText: String {
        guard let summary else {
            return backend.models.isEmpty ? "Loading model catalog" : "\(backend.models.count) MLX models available"
        }
        return "\(summary.files.count) files · \(summary.model) · \(FileHelpers.formattedDurationWithRawSeconds(summary.elapsedSeconds))"
    }
}

struct StemRowView: View {
    let stem: StemFile
    let isPlaying: Bool
    let playAction: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Button(action: playAction) {
                Image(systemName: isPlaying ? "stop.fill" : iconName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(color)
                    .frame(width: 34, height: 34)
                    .background(color.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .help(isPlaying ? "Stop preview" : "Preview stem")

            VStack(alignment: .leading, spacing: 3) {
                Text(stem.displayName)
                    .font(.callout.weight(.semibold))
                HStack(spacing: 8) {
                    Text(stem.fileName)
                        .lineLimit(1)
                    Text(FileHelpers.formattedBytes(stem.sizeBytes))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 10) {
                Button {
                    FileHelpers.reveal(path: stem.path)
                } label: {
                    Image(systemName: "folder")
                }
                .help("Reveal in Finder")

                Button {
                    FileHelpers.copyPath(stem.path)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copy path")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var iconName: String {
        StemRoleStyle.systemImage(for: stem.stem)
    }

    private var color: Color {
        StemRoleStyle.color(for: stem.stem)
    }
}
