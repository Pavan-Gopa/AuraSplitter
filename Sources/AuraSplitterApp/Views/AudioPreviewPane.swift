import AppKit
import SwiftUI

struct AudioPreviewPane: View {
    let analysis: AudioAnalysis?
    let analysisError: String?
    let isAnalyzing: Bool
    let previewProgress: AudioPreviewProgress?
    @ObservedObject var player: AudioPreviewPlayer
    /// When true, chrome shows exit-fullscreen control; parent expands layout.
    @Binding var isFullscreen: Bool
    @State private var viewport = AudioPreviewViewport()
    @State private var layerSettings = AudioPreviewLayerSettings()
    @State private var previousPath: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            previewCanvas
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(KSTheme.canvasBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: isFullscreen ? 0 : KSTheme.radiusLG)
                        .strokeBorder(KSTheme.hairline, lineWidth: isFullscreen ? 0 : 1)
                )
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(isFullscreen ? 1 : 0.38))
        .onChange(of: analysis?.path) { newPath in
            if let newPath {
                if let oldPath = previousPath, baseSongName(from: oldPath) == baseSongName(from: newPath) {
                    // Same song (or its stems) - preserve zoom!
                } else {
                    viewport.reset()
                }
                previousPath = newPath
            } else {
                viewport.reset()
                previousPath = nil
            }
        }
    }

    private func baseSongName(from path: String) -> String {
        let fileStem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let parts = fileStem.components(separatedBy: "_(")
        if let first = parts.first, !first.isEmpty {
            return first
        }
        return fileStem
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

            Spacer(minLength: 10)

            spectrumLowSlider
            spectrumHighSlider
            waveformSlider
            layerResetButton
            volumeControl

            Button {
                isFullscreen.toggle()
            } label: {
                Image(systemName: isFullscreen
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.borderless)
            .help(isFullscreen ? "Exit full screen preview" : "Expand preview to full screen")
            .accessibilityLabel(isFullscreen ? "Exit full screen" : "Full screen preview")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var previewCanvas: some View {
        GeometryReader { geometry in
            let plotRect = plotRect(for: geometry.size)
            ZStack(alignment: .topLeading) {
                KSTheme.canvasBackground

                if let analysis {
                    MetalSpectrogramView(
                        sourceID: analysis.path,
                        spectrogram: analysis.spectrogram!,
                        viewport: viewport,
                        minDb: layerSettings.spectrumMinDb,
                        maxDb: layerSettings.spectrumMaxDb
                    )
                    .frame(width: plotRect.width, height: plotRect.height)
                    .position(x: plotRect.midX, y: plotRect.midY)
                    .allowsHitTesting(false)
                } else if let progress = previewProgress, let spectrogram = progress.partialSpectrogram {
                    MetalSpectrogramView(
                        sourceID: progress.path,
                        spectrogram: spectrogram,
                        viewport: viewport,
                        minDb: layerSettings.spectrumMinDb,
                        maxDb: layerSettings.spectrumMaxDb
                    )
                    .frame(width: plotRect.width, height: plotRect.height)
                    .position(x: plotRect.midX, y: plotRect.midY)
                    .allowsHitTesting(false)
                }

                Canvas { context, size in
                    if let analysis {
                        drawAnalysisOverlay(context: &context, size: size, analysis: analysis)
                    } else if let progress = previewProgress, let waveform = progress.currentWaveform, !waveform.isEmpty {
                        drawProgressiveOverlay(context: &context, size: size, progress: progress, waveform: waveform)
                    } else {
                        drawPlaceholder(context: &context, size: size, message: isAnalyzing ? nil : "No source loaded")
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

                if let progress = previewProgress, progress.isSpectrogramLoading, progress.partialSpectrogram == nil {
                    SpectrogramShimmer()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
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

    private var spectrumLowSlider: some View {
        HStack(spacing: 4) {
            Image(systemName: "waveform.path")
                .foregroundStyle(KSTheme.spectrogramAccent)
                .frame(width: 14)
            Text("Low")
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(
                value: $layerSettings.spectrumMinDb,
                in: -200...(-60),
                step: 1
            )
            .tint(KSTheme.spectrogramAccent)
            .frame(width: 72)
            Text("\(Int(layerSettings.spectrumMinDb.rounded())) dB")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
        .help("Amplitude range (low) [dB]")
    }

    private var spectrumHighSlider: some View {
        HStack(spacing: 4) {
            Text("High")
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(
                value: $layerSettings.spectrumMaxDb,
                in: -60...0,
                step: 1
            )
            .tint(KSTheme.spectrogramAccent)
            .frame(width: 72)
            Text("\(Int(layerSettings.spectrumMaxDb.rounded())) dB")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
        }
        .help("Amplitude range (high) [dB]")
    }

    private var waveformSlider: some View {
        HStack(spacing: 5) {
            Image(systemName: "waveform")
                .foregroundStyle(KSTheme.waveformBlue)
                .frame(width: 14)
            Slider(
                value: Binding(
                    get: { layerSettings.waveformIntensity },
                    set: { layerSettings.waveformIntensity = AudioPreviewLayerSettings.clampIntensity($0) }
                ),
                in: 0...2,
                step: 0.05
            )
            .tint(KSTheme.waveformBlue)
            .frame(width: 86)
        }
        .help("Waveform intensity")
    }

    private var layerResetButton: some View {
        Button {
            layerSettings = AudioPreviewLayerSettings()
        } label: {
            Image(systemName: "arrow.counterclockwise")
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .help("Reset preview layers")
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

    private func drawPlaceholder(context: inout GraphicsContext, size: CGSize, message: String?) {
        let plotRect = plotRect(for: size)
        drawGrid(context: &context, plotRect: plotRect, duration: 0)
        if let message {
            let center = CGPoint(x: plotRect.midX, y: plotRect.midY)
            drawText(message, font: .caption, color: .secondary, context: &context, at: center, anchor: .center)
        }
    }

    private func drawAnalysisOverlay(context: inout GraphicsContext, size: CGSize, analysis: AudioAnalysis) {
        let plotRect = plotRect(for: size)
        guard plotRect.width > 8, plotRect.height > 8 else { return }

        drawGrid(context: &context, plotRect: plotRect, duration: analysis.durationSeconds)
        drawWaveform(
            context: &context,
            plotRect: plotRect,
            peaks: analysis.waveformPeaks!,
            clipped: analysis.clipped,
            intensity: layerSettings.waveformIntensity
        )
        drawAxisLabels(context: &context, plotRect: plotRect, analysis: analysis)
        drawPlayhead(context: &context, plotRect: plotRect, analysis: analysis)
    }

    private func drawProgressiveOverlay(context: inout GraphicsContext, size: CGSize, progress: AudioPreviewProgress, waveform: [Double]) {
        let plotRect = plotRect(for: size)
        guard plotRect.width > 8, plotRect.height > 8 else { return }

        drawGrid(context: &context, plotRect: plotRect, duration: progress.durationSeconds)
        drawWaveform(
            context: &context,
            plotRect: plotRect,
            peaks: waveform,
            clipped: progress.clipped,
            intensity: layerSettings.waveformIntensity
        )
    }

    private func plotRect(for size: CGSize) -> CGRect {
        let horizontalInset: CGFloat = 34
        let topInset: CGFloat = 14
        let bottomInset: CGFloat = 24
        let rightInset: CGFloat = 64
        return CGRect(
            x: horizontalInset,
            y: topInset,
            width: max(1, size.width - horizontalInset - rightInset),
            height: max(1, size.height - topInset - bottomInset)
        )
    }

    private func drawWaveform(context: inout GraphicsContext, plotRect: CGRect, peaks: [Double], clipped: Bool, intensity: Double) {
        let intensity = AudioPreviewLayerSettings.clampIntensity(intensity)
        guard !peaks.isEmpty, intensity > 0.001 else { return }
        let centerY = plotRect.midY
        let maxAmplitude = plotRect.height * 0.23
        let lastIndex = max(1, peaks.count - 1)
        let visibleSamples = max(1, Int(ceil(Double(peaks.count) * viewport.span)))
        let drawPoints = min(max(96, Int(plotRect.width * 1.25)), max(1, visibleSamples * 2))
        guard drawPoints > 1 else { return }

        var topPoints: [CGPoint] = []
        var bottomPoints: [CGPoint] = []
        topPoints.reserveCapacity(drawPoints)
        bottomPoints.reserveCapacity(drawPoints)

        for pointIndex in 0..<drawPoints {
            let visibleFraction = Double(pointIndex) / Double(drawPoints - 1)
            let absoluteFraction = viewport.absoluteFraction(forVisibleFraction: visibleFraction)
            let sourceIndex = absoluteFraction * Double(lastIndex)
            let amplitude = samplePeaks(peaks, index: sourceIndex) * maxAmplitude
            let x = plotRect.minX + CGFloat(visibleFraction) * plotRect.width
            topPoints.append(CGPoint(x: x, y: centerY - amplitude))
            bottomPoints.append(CGPoint(x: x, y: centerY + amplitude))
        }

        let color = clipped ? KSTheme.clippingRed : KSTheme.waveformBlue
        // Primary look = filled blue envelope; opacity scales with intensity.
        // Stroke stays thin/secondary so the fill, not the outline, dominates.
        let fillOpacity = min(0.85, 0.28 + 0.42 * intensity)
        let lineOpacity = min(0.55, 0.35 * intensity)
        let lineWidth = 0.6 + min(0.5, intensity) * 0.3
        var envelope = Path()
        if let first = topPoints.first {
            envelope.move(to: first)
            for point in topPoints.dropFirst() {
                envelope.addLine(to: point)
            }
            for point in bottomPoints.reversed() {
                envelope.addLine(to: point)
            }
            envelope.closeSubpath()
            context.fill(envelope, with: .color(color.opacity(fillOpacity)))
        }

        var crest = Path()
        if let first = topPoints.first {
            crest.move(to: first)
            for point in topPoints.dropFirst() {
                crest.addLine(to: point)
            }
        }
        if let first = bottomPoints.first {
            crest.move(to: first)
            for point in bottomPoints.dropFirst() {
                crest.addLine(to: point)
            }
        }
        context.stroke(crest, with: .color(color.opacity(lineOpacity)), lineWidth: lineWidth)

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

    private func drawFrequencyAxis(context: inout GraphicsContext, plotRect: CGRect, sampleRate: Double) {
        let fMin = 20.0
        let fMax = sampleRate / 2.0
        let melMin = 2595.0 * log10(1.0 + fMin / 700.0)
        let melMax = 2595.0 * log10(1.0 + fMax / 700.0)
        
        let labelX: CGFloat = 6
        let ticks: [Double] = [100, 300, 500, 1000, 2000, 3500, 5000, 7000, 10000, 15000, 20000]
        
        for f in ticks {
            guard f < fMax else { continue }
            let mel = 2595.0 * log10(1.0 + f / 700.0)
            let fractionY = 1.0 - (mel - melMin) / (melMax - melMin)
            let y = plotRect.minY + CGFloat(fractionY) * plotRect.height
            
            // Draw a tiny tick on the left border of plotRect
            var tick = Path()
            tick.move(to: CGPoint(x: plotRect.minX, y: y))
            tick.addLine(to: CGPoint(x: plotRect.minX + 4, y: y))
            context.stroke(tick, with: .color(Color.white.opacity(0.24)), lineWidth: 1)
            
            // Draw the label
            let label = f >= 1000 ? String(format: "%.0fk", f / 1000.0) : String(format: "%.0f", f)
            drawText(
                label,
                font: .caption2.monospacedDigit(),
                color: Color.white.opacity(0.45),
                context: &context,
                at: CGPoint(x: labelX, y: y),
                anchor: .leading
            )
        }
    }

    private func drawAxisLabels(context: inout GraphicsContext, plotRect: CGRect, analysis: AudioAnalysis) {
        drawText(
            analysis.channels == 1 ? "Mono" : "Stereo",
            font: .caption2.weight(.semibold),
            color: Color.white.opacity(0.35),
            context: &context,
            at: CGPoint(x: plotRect.minX, y: plotRect.minY - 14),
            anchor: .leading
        )

        drawFrequencyAxis(context: &context, plotRect: plotRect, sampleRate: Double(analysis.sampleRate))
        drawWaveformDecibelAxis(context: &context, plotRect: plotRect)
    }

    private func drawWaveformDecibelAxis(context: inout GraphicsContext, plotRect: CGRect) {
        let tickX = plotRect.maxX + 10
        let labelX = plotRect.maxX + 22
        let centerY = plotRect.midY
        let halfHeight = plotRect.height / 2
        // Neutral ticks (not red/pink) — labels stay secondary.
        let tickColor = Color.white
        var labelPositions = [centerY]

        drawText("dB", font: .caption2, color: .secondary, context: &context, at: CGPoint(x: labelX, y: plotRect.minY - 5), anchor: .leading)

        for tick in AudioPreviewAxisScale.decibelTicks {
            let offset = CGFloat(tick.amplitudeFraction) * halfHeight
            let upperY = centerY - offset
            let lowerY = centerY + offset
            let showUpperLabel = tick.isMajor && reserveAxisLabel(at: upperY, in: &labelPositions)
            let showLowerLabel = tick.isMajor && reserveAxisLabel(at: lowerY, in: &labelPositions)
            drawDecibelTick(tick, y: upperY, tickX: tickX, labelX: labelX, tickColor: tickColor, showLabel: showUpperLabel, context: &context)
            drawDecibelTick(tick, y: lowerY, tickX: tickX, labelX: labelX, tickColor: tickColor, showLabel: showLowerLabel, context: &context)
        }

        var centerTick = Path()
        centerTick.move(to: CGPoint(x: tickX - 10, y: centerY))
        centerTick.addLine(to: CGPoint(x: tickX, y: centerY))
        context.stroke(centerTick, with: .color(Color.white.opacity(0.28)), lineWidth: 1)
        drawText("-inf", font: .caption2.monospacedDigit(), color: .secondary, context: &context, at: CGPoint(x: labelX, y: centerY), anchor: .leading)
    }

    private func reserveAxisLabel(at y: CGFloat, in positions: inout [CGFloat]) -> Bool {
        let minimumDistance: CGFloat = 10
        guard positions.allSatisfy({ abs($0 - y) >= minimumDistance }) else { return false }
        positions.append(y)
        return true
    }

    private func drawDecibelTick(
        _ tick: AudioPreviewAxisTick,
        y: CGFloat,
        tickX: CGFloat,
        labelX: CGFloat,
        tickColor: Color,
        showLabel: Bool,
        context: inout GraphicsContext
    ) {
        let tickLength: CGFloat = tick.isMajor ? 14 : 7
        var path = Path()
        path.move(to: CGPoint(x: tickX - tickLength, y: y))
        path.addLine(to: CGPoint(x: tickX, y: y))
        context.stroke(path, with: .color(tickColor.opacity(tick.isMajor ? 0.38 : 0.18)), lineWidth: tick.isMajor ? 1.2 : 0.9)

        guard showLabel else { return }
        drawText(
            tick.label,
            font: .caption2.monospacedDigit(),
            color: .secondary,
            context: &context,
            at: CGPoint(x: labelX, y: y),
            anchor: .leading
        )
    }

    private func drawPlayhead(context: inout GraphicsContext, plotRect: CGRect, analysis: AudioAnalysis) {
        guard analysis.durationSeconds > 0 else { return }
        let absoluteFraction = min(1, max(0, currentPreviewTime / analysis.durationSeconds))
        guard let visibleFraction = viewport.visibleFraction(forAbsoluteFraction: absoluteFraction) else { return }
        let x = plotRect.minX + plotRect.width * CGFloat(visibleFraction)

        var line = Path()
        line.move(to: CGPoint(x: x, y: plotRect.minY - 7))
        line.addLine(to: CGPoint(x: x, y: plotRect.maxY))
        context.stroke(line, with: .color(KSTheme.playheadAmber), lineWidth: 1.5)

        let knobRect = CGRect(x: x - 5, y: plotRect.minY - 11, width: 10, height: 10)
        context.fill(Path(ellipseIn: knobRect), with: .color(KSTheme.playheadAmber))
    }

    private func samplePeaks(_ peaks: [Double], index: Double) -> CGFloat {
        guard !peaks.isEmpty else { return 0 }
        let left = min(peaks.count - 1, max(0, Int(floor(index))))
        let right = min(peaks.count - 1, left + 1)
        let mix = min(1, max(0, index - Double(left)))
        let value = peaks[left] + (peaks[right] - peaks[left]) * mix
        return CGFloat(min(1, max(0, value)))
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

struct AudioPreviewInteractionView: NSViewRepresentable {
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

final class AudioPreviewInteractionNSView: NSView {
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

private struct SpectrogramShimmer: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            LinearGradient(
                colors: KSTheme.shimmerColors,
                startPoint: UnitPoint(x: phase, y: 0),
                endPoint: UnitPoint(x: phase + 0.4, y: 0)
            )
            .frame(width: geometry.size.width, height: geometry.size.height)
            .onAppear {
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    phase = 1.0
                }
            }
        }
    }
}
