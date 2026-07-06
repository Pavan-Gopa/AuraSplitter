import AppKit
import SwiftUI

struct AudioPreviewPane: View {
    let analysis: AudioAnalysis?
    let analysisError: String?
    let isAnalyzing: Bool
    @ObservedObject var player: AudioPreviewPlayer
    @State private var viewport = AudioPreviewViewport()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            previewCanvas
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(red: 0.015, green: 0.018, blue: 0.026))
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.38))
        .onChange(of: analysis?.path) { _ in
            viewport.reset()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: togglePlayback) {
                Image(systemName: isPlayingCurrentSource ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.space, modifiers: [])
            .disabled(analysis == nil)
            .help(isPlayingCurrentSource ? "Pause source preview" : "Play source preview")

            VStack(alignment: .leading, spacing: 3) {
                Text(analysis?.filename ?? "Audio Preview")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(timeLineText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 10)

            if let analysis {
                metricPill(analysis.channelLabel, systemImage: analysis.channels == 1 ? "circle.lefthalf.filled" : "circle.grid.cross")
                metricPill(FileHelpers.formattedDuration(analysis.durationSeconds), systemImage: "timer")
                metricPill(analysis.peakLabel, systemImage: "meter.waveform", warning: analysis.clipped || analysis.peakDb >= -0.25)
            }

            if viewport.isZoomed {
                metricPill("\(String(format: "%.1fx", viewport.zoomFactor))", systemImage: "plus.magnifyingglass")
                Button {
                    viewport.reset()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .help("Fit full audio")
            }

            volumeControl
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var previewCanvas: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    drawBackground(context: &context, size: size)
                    if let analysis {
                        drawAnalysis(context: &context, size: size, analysis: analysis)
                    } else {
                        drawPlaceholder(context: &context, size: size)
                    }
                }

                AudioPreviewInteractionView(
                    onSeek: { location, size in
                        seek(at: location, in: size)
                    },
                    onScroll: { deltaY, location, size in
                        zoom(deltaY: deltaY, at: location, in: size)
                    },
                    onMiddleDrag: { deltaX, size in
                        pan(deltaX: deltaX, in: size)
                    },
                    onSpacebar: togglePlayback
                )
                .allowsHitTesting(analysis != nil)

                if let analysisError {
                    Label(analysisError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .padding(10)
                } else if isAnalyzing {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Analyzing audio")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                }
            }
        }
    }

    private var isPlayingCurrentSource: Bool {
        guard let analysis else { return false }
        return player.playingPath == analysis.path && player.isPlaying
    }

    private var currentPreviewTime: Double {
        guard let analysis, player.playingPath == analysis.path else { return 0 }
        return min(max(0, player.currentTime), analysis.durationSeconds)
    }

    private var timeLineText: String {
        guard let analysis else { return "0:00 / 0:00" }
        return "\(FileHelpers.formattedTimestamp(currentPreviewTime)) / \(FileHelpers.formattedTimestamp(analysis.durationSeconds))"
    }

    private var volumeControl: some View {
        HStack(spacing: 7) {
            Image(systemName: player.volume <= 0.01 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { player.volume },
                    set: { player.setVolume($0) }
                ),
                in: 0...3,
                step: 0.05
            )
            .frame(width: 118)
            Text("\(Int((player.volume * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
        }
        .help("Preview volume")
    }

    private func metricPill(_ text: String, systemImage: String, warning: Bool = false) -> some View {
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

    private func seek(at location: CGPoint, in size: CGSize) {
        guard let analysis else { return }
        let plotRect = plotRect(for: size)
        guard plotRect.contains(location) || (location.x >= plotRect.minX && location.x <= plotRect.maxX) else { return }
        let visibleFraction = min(1, max(0, (location.x - plotRect.minX) / max(1, plotRect.width)))
        let absoluteFraction = viewport.absoluteFraction(forVisibleFraction: Double(visibleFraction))
        player.seek(path: analysis.path, time: analysis.durationSeconds * absoluteFraction)
    }

    private func zoom(deltaY: CGFloat, at location: CGPoint, in size: CGSize) {
        let plotRect = plotRect(for: size)
        guard plotRect.contains(location) || (location.x >= plotRect.minX && location.x <= plotRect.maxX) else { return }
        let anchor = min(1, max(0, (location.x - plotRect.minX) / max(1, plotRect.width)))
        viewport.zoom(deltaY: Double(deltaY), anchorFraction: Double(anchor))
    }

    private func pan(deltaX: CGFloat, in size: CGSize) {
        let plotRect = plotRect(for: size)
        viewport.pan(deltaX: Double(deltaX), canvasWidth: Double(plotRect.width))
    }

    private func togglePlayback() {
        guard let analysis else { return }
        player.toggle(path: analysis.path)
    }

    private func drawBackground(context: inout GraphicsContext, size: CGSize) {
        let rect = CGRect(origin: .zero, size: size)
        context.fill(Path(rect), with: .color(Color(red: 0.015, green: 0.018, blue: 0.026)))
    }

    private func drawPlaceholder(context: inout GraphicsContext, size: CGSize) {
        let plotRect = plotRect(for: size)
        drawGrid(context: &context, plotRect: plotRect, duration: 0)
        let center = CGPoint(x: plotRect.midX, y: plotRect.midY)
        drawText("No source loaded", font: .caption, color: .secondary, context: &context, at: center, anchor: .center)
    }

    private func drawAnalysis(context: inout GraphicsContext, size: CGSize, analysis: AudioAnalysis) {
        let plotRect = plotRect(for: size)
        guard plotRect.width > 8, plotRect.height > 8 else { return }

        drawSpectrogram(context: &context, plotRect: plotRect, spectrogram: analysis.spectrogram)
        drawGrid(context: &context, plotRect: plotRect, duration: analysis.durationSeconds)
        drawWaveform(context: &context, plotRect: plotRect, peaks: analysis.waveformPeaks, clipped: analysis.clipped)
        drawAxisLabels(context: &context, size: size, plotRect: plotRect, analysis: analysis)
        drawPlayhead(context: &context, plotRect: plotRect, analysis: analysis)
    }

    private func plotRect(for size: CGSize) -> CGRect {
        let horizontalInset: CGFloat = 34
        let topInset: CGFloat = 14
        let bottomInset: CGFloat = 24
        return CGRect(
            x: horizontalInset,
            y: topInset,
            width: max(1, size.width - horizontalInset - 42),
            height: max(1, size.height - topInset - bottomInset)
        )
    }

    private func drawSpectrogram(context: inout GraphicsContext, plotRect: CGRect, spectrogram: SpectrogramData) {
        let columns = max(1, spectrogram.columns)
        let bins = max(1, spectrogram.bins)
        let values = spectrogram.values
        guard !values.isEmpty else { return }

        let binHeight = plotRect.height / CGFloat(bins)
        let startColumn = max(0, Int(floor(viewport.start * Double(columns))))
        let endColumn = min(columns - 1, Int(ceil(viewport.end * Double(columns))))
        guard startColumn <= endColumn else { return }

        for column in startColumn...endColumn {
            let columnStart = Double(column) / Double(columns)
            let columnEnd = Double(column + 1) / Double(columns)
            let visibleStart = max(0, (columnStart - viewport.start) / viewport.span)
            let visibleEnd = min(1, (columnEnd - viewport.start) / viewport.span)
            let x = plotRect.minX + CGFloat(visibleStart) * plotRect.width
            let columnWidth = max(1, CGFloat(visibleEnd - visibleStart) * plotRect.width)
            for bin in 0..<bins {
                let index = column * bins + bin
                guard index < values.count else { continue }
                let value = min(1, max(0, values[index]))
                guard value > 0.008 else { continue }

                let y = plotRect.maxY - CGFloat(bin + 1) * binHeight
                let rect = CGRect(
                    x: x,
                    y: y,
                    width: columnWidth + 0.35,
                    height: max(1, binHeight + 0.35)
                )
                context.fill(Path(rect), with: .color(spectrogramColor(value)))
            }
        }
    }

    private func drawWaveform(context: inout GraphicsContext, plotRect: CGRect, peaks: [Double], clipped: Bool) {
        guard !peaks.isEmpty else { return }
        let centerY = plotRect.midY
        let maxAmplitude = plotRect.height * 0.23
        var path = Path()
        let lastIndex = max(1, peaks.count - 1)
        let startIndex = max(0, Int(floor(viewport.start * Double(peaks.count))))
        let endIndex = min(peaks.count - 1, Int(ceil(viewport.end * Double(peaks.count))))
        guard startIndex <= endIndex else { return }

        for index in startIndex...endIndex {
            let absoluteFraction = Double(index) / Double(lastIndex)
            guard let visibleFraction = viewport.visibleFraction(forAbsoluteFraction: absoluteFraction) else { continue }
            let x = plotRect.minX + CGFloat(visibleFraction) * plotRect.width
            let amplitude = min(1, max(0, peaks[index])) * maxAmplitude
            path.move(to: CGPoint(x: x, y: centerY - amplitude))
            path.addLine(to: CGPoint(x: x, y: centerY + amplitude))
        }

        let color = clipped ? Color(red: 1.0, green: 0.22, blue: 0.20) : Color(red: 0.18, green: 0.55, blue: 1.0)
        context.stroke(path, with: .color(color.opacity(0.90)), lineWidth: 1.2)

        var centerLine = Path()
        centerLine.move(to: CGPoint(x: plotRect.minX, y: centerY))
        centerLine.addLine(to: CGPoint(x: plotRect.maxX, y: centerY))
        context.stroke(centerLine, with: .color(Color.white.opacity(0.18)), lineWidth: 1)
    }

    private func drawGrid(context: inout GraphicsContext, plotRect: CGRect, duration: Double) {
        let border = Path(plotRect)
        context.stroke(border, with: .color(Color.white.opacity(0.16)), lineWidth: 1)

        var grid = Path()
        let verticalLines = 8
        for index in 0...verticalLines {
            let fraction = CGFloat(index) / CGFloat(verticalLines)
            let x = plotRect.minX + plotRect.width * fraction
            grid.move(to: CGPoint(x: x, y: plotRect.minY))
            grid.addLine(to: CGPoint(x: x, y: plotRect.maxY))

            if duration > 0 {
                let visibleFraction = Double(fraction)
                let absoluteFraction = viewport.absoluteFraction(forVisibleFraction: visibleFraction)
                let label = FileHelpers.formattedTimestamp(duration * absoluteFraction)
                drawText(
                    label,
                    font: .caption2.monospacedDigit(),
                    color: .secondary,
                    context: &context,
                    at: CGPoint(x: x, y: plotRect.maxY + 14),
                    anchor: index == 0 ? .leading : (index == verticalLines ? .trailing : .center)
                )
            }
        }

        for index in 1..<4 {
            let y = plotRect.minY + plotRect.height * CGFloat(index) / 4
            grid.move(to: CGPoint(x: plotRect.minX, y: y))
            grid.addLine(to: CGPoint(x: plotRect.maxX, y: y))
        }

        context.stroke(grid, with: .color(Color.white.opacity(0.08)), lineWidth: 1)
    }

    private func drawAxisLabels(context: inout GraphicsContext, size: CGSize, plotRect: CGRect, analysis: AudioAnalysis) {
        drawText(
            analysis.channels == 1 ? "M" : "L/R",
            font: .caption2.weight(.semibold),
            color: .secondary,
            context: &context,
            at: CGPoint(x: 12, y: plotRect.midY),
            anchor: .leading
        )

        let dbLabels = ["0", "-6", "-12", "-24"]
        for (index, label) in dbLabels.enumerated() {
            let y = plotRect.minY + CGFloat(index) * plotRect.height / CGFloat(max(1, dbLabels.count - 1))
            drawText(
                label,
                font: .caption2.monospacedDigit(),
                color: .secondary,
                context: &context,
                at: CGPoint(x: size.width - 28, y: y),
                anchor: .leading
            )
        }

        drawText("dB", font: .caption2, color: .secondary, context: &context, at: CGPoint(x: size.width - 28, y: plotRect.minY - 5), anchor: .leading)
    }

    private func drawPlayhead(context: inout GraphicsContext, plotRect: CGRect, analysis: AudioAnalysis) {
        guard analysis.durationSeconds > 0 else { return }
        let absoluteFraction = min(1, max(0, currentPreviewTime / analysis.durationSeconds))
        guard let visibleFraction = viewport.visibleFraction(forAbsoluteFraction: absoluteFraction) else { return }
        let x = plotRect.minX + plotRect.width * CGFloat(visibleFraction)

        var line = Path()
        line.move(to: CGPoint(x: x, y: plotRect.minY - 7))
        line.addLine(to: CGPoint(x: x, y: plotRect.maxY))
        context.stroke(line, with: .color(Color(red: 1.0, green: 0.74, blue: 0.18)), lineWidth: 1.5)

        let knobRect = CGRect(x: x - 5, y: plotRect.minY - 11, width: 10, height: 10)
        context.fill(Path(ellipseIn: knobRect), with: .color(Color(red: 1.0, green: 0.74, blue: 0.18)))
    }

    private func spectrogramColor(_ value: Double) -> Color {
        if value < 0.28 {
            let t = value / 0.28
            return Color(red: 0.02 + 0.05 * t, green: 0.05 + 0.12 * t, blue: 0.17 + 0.38 * t)
        }
        if value < 0.68 {
            let t = (value - 0.28) / 0.40
            return Color(red: 0.08 + 0.75 * t, green: 0.18 + 0.26 * t, blue: 0.55 - 0.40 * t)
        }
        let t = (value - 0.68) / 0.32
        return Color(red: 0.83 + 0.17 * t, green: 0.44 + 0.38 * t, blue: 0.15 + 0.05 * t)
    }

    private func drawText(
        _ value: String,
        font: Font,
        color: Color,
        context: inout GraphicsContext,
        at point: CGPoint,
        anchor: UnitPoint
    ) {
        var resolved = context.resolve(Text(value).font(font))
        resolved.shading = .color(color)
        context.draw(resolved, at: point, anchor: anchor)
    }
}

private struct AudioPreviewInteractionView: NSViewRepresentable {
    let onSeek: (CGPoint, CGSize) -> Void
    let onScroll: (CGFloat, CGPoint, CGSize) -> Void
    let onMiddleDrag: (CGFloat, CGSize) -> Void
    let onSpacebar: () -> Void

    func makeNSView(context: Context) -> AudioPreviewInteractionNSView {
        let view = AudioPreviewInteractionNSView()
        view.onSeek = onSeek
        view.onScroll = onScroll
        view.onMiddleDrag = onMiddleDrag
        view.onSpacebar = onSpacebar
        return view
    }

    func updateNSView(_ nsView: AudioPreviewInteractionNSView, context: Context) {
        nsView.onSeek = onSeek
        nsView.onScroll = onScroll
        nsView.onMiddleDrag = onMiddleDrag
        nsView.onSpacebar = onSpacebar
    }
}

private final class AudioPreviewInteractionNSView: NSView {
    var onSeek: ((CGPoint, CGSize) -> Void)?
    var onScroll: ((CGFloat, CGPoint, CGSize) -> Void)?
    var onMiddleDrag: ((CGFloat, CGSize) -> Void)?
    var onSpacebar: (() -> Void)?

    private var lastMiddleDragLocation: CGPoint?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onSeek?(location(for: event), bounds.size)
    }

    override func mouseDragged(with event: NSEvent) {
        onSeek?(location(for: event), bounds.size)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        lastMiddleDragLocation = location(for: event)
        NSCursor.closedHand.push()
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDragged(with: event)
            return
        }
        let current = location(for: event)
        if let previous = lastMiddleDragLocation {
            onMiddleDrag?(current.x - previous.x, bounds.size)
        }
        lastMiddleDragLocation = current
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseUp(with: event)
            return
        }
        lastMiddleDragLocation = nil
        NSCursor.pop()
    }

    override func scrollWheel(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onScroll?(event.scrollingDeltaY, location(for: event), bounds.size)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 {
            onSpacebar?()
            return
        }
        super.keyDown(with: event)
    }

    private func location(for event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }
}
