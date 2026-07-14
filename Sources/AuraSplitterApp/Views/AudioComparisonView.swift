import SwiftUI
import AppKit
import Metal
import MetalKit

struct AudioComparisonView: View {
    let stems: [StemFile]
    @ObservedObject var player: AudioPreviewPlayer
    @ObservedObject var backend: BackendClient
    @Binding var resultPreviewCache: AudioPreviewAnalysisCache
    let onClose: () -> Void

    @State private var viewport = AudioPreviewViewport()
    @State private var activePath: String = ""
    @State private var analyses: [String: AudioAnalysis] = [:]
    @State private var loadingStates: [String: Bool] = [:]
    @State private var errors: [String: String] = [:]
    @State private var layerSettings = AudioPreviewLayerSettings()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            
            VStack(spacing: 8) {
                ForEach(stems) { stem in
                    ComparisonPane(
                        stem: stem,
                        analysis: analyses[stem.path],
                        isLoading: loadingStates[stem.path] ?? false,
                        error: errors[stem.path],
                        isActive: activePath == stem.path,
                        viewport: $viewport,
                        player: player,
                        layerSettings: layerSettings,
                        onActivate: {
                            let currentTime = player.currentTime
                            activePath = stem.path
                            player.seek(path: stem.path, time: currentTime)
                        }
                    )
                    .frame(maxHeight: .infinity)
                }
            }
            .padding(8)
            .background(Color(red: 0.015, green: 0.018, blue: 0.026))
        }
        .background(Color(red: 0.05, green: 0.06, blue: 0.08))
        .onAppear {
            if let first = stems.first {
                activePath = first.path
            }
            loadAnalyses()
        }
    }

    private func loadAnalyses() {
        for stem in stems {
            let path = stem.path
            
            if let cached = resultPreviewCache.analysis(for: path) {
                analyses[path] = cached
                loadingStates[path] = false
                continue
            }
            if let error = resultPreviewCache.error(for: path) {
                errors[path] = error
                loadingStates[path] = false
                continue
            }

            loadingStates[path] = true
            Task {
                do {
                    let shouldStart = await MainActor.run {
                        resultPreviewCache.shouldStartAnalysis(for: path)
                    }
                    guard shouldStart else {
                        let analysis = try await backend.analyzeAudio(url: URL(fileURLWithPath: path))
                        await MainActor.run {
                            resultPreviewCache.store(analysis, for: path)
                            analyses[path] = analysis
                            loadingStates[path] = false
                        }
                        return
                    }
                    
                    let analysis = try await backend.analyzeAudio(url: URL(fileURLWithPath: path))
                    await MainActor.run {
                        resultPreviewCache.store(analysis, for: path)
                        analyses[path] = analysis
                        loadingStates[path] = false
                    }
                } catch {
                    await MainActor.run {
                        resultPreviewCache.storeError(error.localizedDescription, for: path)
                        errors[path] = error.localizedDescription
                        loadingStates[path] = false
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Button(action: onClose) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.headline)
                    Text("Back to Results")
                        .font(.body.weight(.semibold))
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)

            Spacer()

            Text("Stem Comparison")
                .font(.headline)
                .foregroundStyle(.primary)

            Spacer()

            if let activeAnalysis = analyses[activePath] {
                Text("\(FileHelpers.formattedTimestamp(player.currentTime)) / \(FileHelpers.formattedTimestamp(activeAnalysis.durationSeconds))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Button {
                player.toggle(path: activePath)
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(Color.orange, in: Circle())
                    .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
            .disabled(analyses[activePath] == nil)

            if viewport.isZoomed {
                Button {
                    viewport.reset()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("Fit full audio")
            }

            volumeControl
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(red: 0.08, green: 0.10, blue: 0.14))
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
            .frame(width: 100)
            Text("\(Int((player.volume * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }
}

struct ComparisonPane: View {
    let stem: StemFile
    let analysis: AudioAnalysis?
    let isLoading: Bool
    let error: String?
    let isActive: Bool
    @Binding var viewport: AudioPreviewViewport
    @ObservedObject var player: AudioPreviewPlayer
    let layerSettings: AudioPreviewLayerSettings
    let onActivate: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(stem.displayName)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(isActive ? .orange : .primary)
                Spacer()
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                } else {
                    Text(stem.fileName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(isActive ? Color.orange.opacity(0.12) : Color.white.opacity(0.03))

            GeometryReader { geometry in
                let plotRect = plotRect(for: geometry.size)
                ZStack(alignment: .topLeading) {
                    Color(red: 0.015, green: 0.018, blue: 0.026)

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
                    }

                    Canvas { context, size in
                        if let analysis {
                            drawAnalysisOverlay(context: &context, size: size, analysis: analysis)
                        } else {
                            drawPlaceholder(context: &context, size: size, message: isLoading ? nil : "No preview loaded")
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
                        onSpacebar: {
                            player.toggle(path: stem.path)
                        }
                    )
                    .allowsHitTesting(analysis != nil)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    onActivate()
                }
            }
        }
        .background(Color(red: 0.02, green: 0.02, blue: 0.03))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(isActive ? Color.orange : Color.clear, lineWidth: 1.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func plotRect(for size: CGSize) -> CGRect {
        let horizontalInset: CGFloat = 34
        let topInset: CGFloat = 8
        let bottomInset: CGFloat = 16
        let rightInset: CGFloat = 48
        return CGRect(
            x: horizontalInset,
            y: topInset,
            width: max(1, size.width - horizontalInset - rightInset),
            height: max(1, size.height - topInset - bottomInset)
        )
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

        let color = clipped ? Color(red: 1.0, green: 0.22, blue: 0.20) : Color(red: 0.18, green: 0.55, blue: 1.0)
        let fillOpacity = min(0.55, 0.28 * intensity)
        let lineOpacity = min(1.0, 0.95 * intensity)
        let lineWidth = 0.8 + min(1.2, intensity) * 0.35
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
                    at: CGPoint(x: x, y: plotRect.maxY + 10),
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

    private func drawAxisLabels(context: inout GraphicsContext, plotRect: CGRect, analysis: AudioAnalysis) {
        drawText(
            analysis.channels == 1 ? "M" : "L/R",
            font: .caption2.weight(.semibold),
            color: .secondary,
            context: &context,
            at: CGPoint(x: 12, y: plotRect.midY),
            anchor: .leading
        )

        drawWaveformDecibelAxis(context: &context, plotRect: plotRect)
    }

    private func drawWaveformDecibelAxis(context: inout GraphicsContext, plotRect: CGRect) {
        let tickX = plotRect.maxX + 6
        let labelX = plotRect.maxX + 14
        let centerY = plotRect.midY
        let halfHeight = plotRect.height / 2
        let tickColor = Color(red: 1.0, green: 0.18, blue: 0.32)
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
        centerTick.move(to: CGPoint(x: tickX - 6, y: centerY))
        centerTick.addLine(to: CGPoint(x: tickX, y: centerY))
        context.stroke(centerTick, with: .color(Color.white.opacity(0.22)), lineWidth: 1)
        drawText("-inf", font: .caption2.monospacedDigit(), color: .secondary, context: &context, at: CGPoint(x: labelX, y: centerY), anchor: .leading)
    }

    private func reserveAxisLabel(at y: CGFloat, in positions: inout [CGFloat]) -> Bool {
        let minimumDistance: CGFloat = 8
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
        let tickLength: CGFloat = tick.isMajor ? 10 : 5
        var path = Path()
        path.move(to: CGPoint(x: tickX - tickLength, y: y))
        path.addLine(to: CGPoint(x: tickX, y: y))
        context.stroke(path, with: .color(tickColor.opacity(tick.isMajor ? 0.95 : 0.58)), lineWidth: tick.isMajor ? 1.7 : 1.1)

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
        let absoluteFraction = min(1, max(0, player.currentTime / analysis.durationSeconds))
        guard let visibleFraction = viewport.visibleFraction(forAbsoluteFraction: absoluteFraction) else { return }
        let x = plotRect.minX + plotRect.width * CGFloat(visibleFraction)

        var line = Path()
        line.move(to: CGPoint(x: x, y: plotRect.minY - 4))
        line.addLine(to: CGPoint(x: x, y: plotRect.maxY))
        context.stroke(line, with: .color(Color(red: 1.0, green: 0.74, blue: 0.18)), lineWidth: 1.5)

        let knobRect = CGRect(x: x - 4, y: plotRect.minY - 8, width: 8, height: 8)
        context.fill(Path(ellipseIn: knobRect), with: .color(Color(red: 1.0, green: 0.74, blue: 0.18)))
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

    private func seek(at location: CGPoint, in size: CGSize) {
        guard let analysis else { return }
        let plotRect = plotRect(for: size)
        guard plotRect.contains(location) || (location.x >= plotRect.minX && location.x <= plotRect.maxX) else { return }
        let visibleFraction = min(1, max(0, (location.x - plotRect.minX) / max(1, plotRect.width)))
        let absoluteFraction = viewport.absoluteFraction(forVisibleFraction: Double(visibleFraction))
        
        player.seek(path: player.playingPath ?? stem.path, time: analysis.durationSeconds * absoluteFraction)
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
}
