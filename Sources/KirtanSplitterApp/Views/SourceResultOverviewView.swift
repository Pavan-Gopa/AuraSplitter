import SwiftUI

struct SourceResultOverviewView: View {
    @ObservedObject var backend: BackendClient
    let inputURL: URL?
    let sourceAnalysis: AudioAnalysis?
    let analysisError: String?
    let results: [StemFile]
    let summary: SeparationSummary?
    @ObservedObject var previewPlayer: StemPreviewPlayer

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
        VStack(alignment: .leading, spacing: 14) {
            columnHeader(title: "Source", systemImage: "waveform")

            if let inputURL {
                VStack(alignment: .leading, spacing: 6) {
                    Text(inputURL.lastPathComponent)
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Text(inputURL.deletingLastPathComponent().path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if let sourceAnalysis {
                    sourceStats(analysis: sourceAnalysis)
                } else if let analysisError {
                    warningLine(text: analysisError)
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Analyzing audio")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                emptyColumnText("Drop or choose a source recording.")
            }

            Spacer(minLength: 0)
        }
        .padding(18)
    }

    private var resultColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            columnHeader(title: "Result", systemImage: "square.stack.3d.up")

            if let summary {
                VStack(alignment: .leading, spacing: 5) {
                    Text(summary.model)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text("\(results.count) stems · \(FileHelpers.formattedDurationWithRawSeconds(summary.elapsedSeconds))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                emptyColumnText(backend.isProcessing ? backend.currentStage : "Separated stems will appear here.")
            }

            if !results.isEmpty {
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

            Spacer(minLength: 0)
        }
        .padding(18)
    }

    private func columnHeader(title: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Spacer()
        }
    }

    private func sourceStats(analysis: AudioAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                statPill(analysis.channelLabel, systemImage: analysis.channels == 1 ? "circle.lefthalf.filled" : "circle.grid.cross")
                statPill(FileHelpers.formattedDuration(analysis.durationSeconds), systemImage: "timer")
                statPill("\(analysis.sampleRate) Hz", systemImage: "dot.radiowaves.left.and.right")
            }
            HStack(spacing: 8) {
                statPill(analysis.peakLabel, systemImage: "meter.waveform", warning: analysis.clipped || analysis.peakDb >= -0.25)
                if analysis.clipped || analysis.peakDb >= -0.25 {
                    warningLine(text: "Peak is at or near 0 dBFS. Repair or attenuate before separation.")
                }
            }
        }
    }

    private func statPill(_ text: String, systemImage: String, warning: Bool = false) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
            Text(text)
                .monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(warning ? .red : .secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background((warning ? Color.red : Color.secondary).opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
    }

    private func warningLine(text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func emptyColumnText(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
