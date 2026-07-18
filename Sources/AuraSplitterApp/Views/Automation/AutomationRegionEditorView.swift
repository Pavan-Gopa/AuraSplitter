import AppKit
import SwiftUI

/// Regions step: audio player + red exclusion zones (parts to remove before separation).
struct AutomationRegionEditorView: View {
    @ObservedObject var store: AutomationWizardStore
    @ObservedObject var backend: BackendClient
    @StateObject private var player = AudioPreviewPlayer()

    @State private var analysis: AudioAnalysis?
    @State private var isAnalyzing = false
    @State private var analysisError: String?
    @State private var layerSettings = AudioPreviewLayerSettings()
    @State private var viewport = AudioPreviewViewport()
    @State private var selectedZoneID: UUID?
    @State private var dragMode: ZoneDragMode = .none
    @State private var dragOriginalZone: AutomationTimeRange?
    @State private var canvasSize: CGSize = .zero

    private enum ZoneDragMode {
        case none, create, move, resizeLeft, resizeRight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("Cut regions")
                    .font(.headline)
                Spacer()
                if !store.job.selectedTracks.isEmpty {
                    Picker("Track", selection: Binding(
                        get: { store.job.regionEditorTrackID ?? store.job.selectedTracks.first?.id },
                        set: { store.job.regionEditorTrackID = $0 }
                    )) {
                        ForEach(store.job.selectedTracks) { track in
                            Text(track.displayName).tag(Optional(track.id))
                        }
                    }
                    .frame(maxWidth: 280)
                }
            }

            Text("Drag to mark parts to remove. Edge handles resize. Shift+drag adds a zone. Scroll zooms, middle-drag pans, Space plays. Playback skips red zones. Zones apply to all selected tracks.")
                .font(.caption)
                .foregroundStyle(.secondary)

            toolbar

            timeline
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(KSTheme.canvasBackground, in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))

            HStack {
                Button("CLEAR") {
                    if let id = currentTrackID {
                        store.clearZones(for: id)
                        selectedZoneID = nil
                    }
                }
                .controlSize(.small)
                .disabled(currentZones.isEmpty)
                .help("Clear all exclusion zones on selected tracks")

                if selectedZoneID != nil {
                    Button(role: .destructive) {
                        deleteSelectedZone()
                    } label: {
                        Label("Delete zone", systemImage: "trash")
                    }
                    .controlSize(.small)
                    .help("Delete the selected (highlighted) zone")
                }

                Spacer()
                Text("\(currentZones.count) zone(s) · all selected tracks")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .task(id: currentTrackID) {
            await loadAnalysisForCurrentTrack()
        }
        .onDisappear {
            player.stop()
        }
        .onReceive(Timer.publish(every: 0.03, on: .main, in: .common).autoconnect()) { _ in
            skipPlaybackThroughZonesIfNeeded()
        }
    }

    // MARK: - Derived

    private var currentTrackID: UUID? {
        store.job.regionEditorTrackID ?? store.job.selectedTracks.first?.id
    }

    private var currentTrack: AutomationTrackPlan? {
        guard let id = currentTrackID else { return nil }
        return store.job.tracks.first(where: { $0.id == id })
    }

    private var currentZones: [AutomationTimeRange] {
        currentTrack?.exclusionZones ?? []
    }

    private var duration: Double {
        analysis?.durationSeconds ?? max(player.duration, 0)
    }

    private var isPlaying: Bool {
        guard let path = currentTrack?.sourcePath else { return false }
        return player.playingPath == path && player.isPlaying
    }

    private var timeLabel: String {
        let t = player.playingPath == currentTrack?.sourcePath ? player.currentTime : 0
        return "\(FileHelpers.formattedTimestamp(t)) / \(FileHelpers.formattedTimestamp(duration))"
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button {
                togglePlayback()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .disabled(currentTrack == nil || (analysis == nil && !isAnalyzing))
            .keyboardShortcut(.space, modifiers: [])
            .help("Play / pause (Space)")

            Text(timeLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            if isAnalyzing {
                ProgressView().controlSize(.small)
                Text("Analyzing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let analysisError {
                Text(analysisError)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }

            if viewport.isZoomed {
                Button {
                    viewport.reset()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.borderless)
                .help("Fit full duration")
            }

            Spacer()
        }
    }

    // MARK: - Timeline

    private var timeline: some View {
        GeometryReader { geo in
            let plot = plotRect(in: geo.size)
            ZStack {
                KSTheme.canvasBackground

                if let analysis, let spectrogram = analysis.spectrogram {
                    MetalSpectrogramView(
                        sourceID: analysis.path,
                        spectrogram: spectrogram,
                        viewport: viewport,
                        minDb: layerSettings.spectrumMinDb,
                        maxDb: layerSettings.spectrumMaxDb
                    )
                    .frame(width: plot.width, height: plot.height)
                    .position(x: plot.midX, y: plot.midY)
                    .allowsHitTesting(false)
                }

                Canvas { context, size in
                    let plot = plotRect(in: size)
                    drawWaveform(context: &context, plot: plot)
                    drawZones(context: &context, plot: plot)
                    drawPlayhead(context: &context, plot: plot)
                }
                .allowsHitTesting(false)

                // Zoom / pan / Space (left mouse off so zone drag works).
                AudioPreviewInteractionView(
                    onSeek: { _, _ in },
                    onScroll: { deltaY, location, size in
                        let plot = plotRect(in: size)
                        let anchor = min(1, max(0, Double((location.x - plot.minX) / max(1, plot.width))))
                        viewport.zoom(deltaY: Double(deltaY), anchorFraction: anchor)
                    },
                    onMiddleDrag: { deltaX, size in
                        viewport.pan(deltaX: Double(deltaX), canvasWidth: Double(max(1, size.width)))
                    },
                    onSpacebar: {
                        togglePlayback()
                    },
                    handlesLeftMouse: false
                )

                // Zone create/move/resize on top for left-drag.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(zoneDragGesture(plot: plot))
            }
            .onAppear { canvasSize = geo.size }
            .onChange(of: geo.size) { canvasSize = $0 }
        }
    }

    private func plotRect(in size: CGSize) -> CGRect {
        CGRect(x: 12, y: 12, width: max(1, size.width - 24), height: max(1, size.height - 24))
    }

    private func time(atX x: CGFloat, plot: CGRect) -> Double {
        guard plot.width > 0, duration > 0 else { return 0 }
        let frac = min(1, max(0, Double((x - plot.minX) / plot.width)))
        return viewport.absoluteFraction(forVisibleFraction: frac) * duration
    }

    private func xPosition(forTime t: Double, plot: CGRect) -> CGFloat {
        guard duration > 0 else { return plot.minX }
        let absFrac = min(1, max(0, t / duration))
        guard let vis = viewport.visibleFraction(forAbsoluteFraction: absFrac) else {
            if absFrac < viewport.start { return plot.minX }
            return plot.maxX
        }
        return plot.minX + CGFloat(vis) * plot.width
    }

    // MARK: - Draw

    private func drawWaveform(context: inout GraphicsContext, plot: CGRect) {
        guard let peaks = analysis?.waveformPeaks, !peaks.isEmpty else { return }
        let centerY = plot.midY
        let maxAmp = plot.height * 0.22
        let n = min(max(64, Int(plot.width)), peaks.count)
        var top: [CGPoint] = []
        var bottom: [CGPoint] = []
        for i in 0..<n {
            let vis = Double(i) / Double(max(1, n - 1))
            let absF = viewport.absoluteFraction(forVisibleFraction: vis)
            let idx = absF * Double(peaks.count - 1)
            let left = Int(floor(idx))
            let right = min(peaks.count - 1, left + 1)
            let mix = idx - Double(left)
            let amp = (peaks[left] * (1 - mix) + peaks[right] * mix) * maxAmp
            let px = plot.minX + CGFloat(vis) * plot.width
            top.append(CGPoint(x: px, y: centerY - amp))
            bottom.append(CGPoint(x: px, y: centerY + amp))
        }
        var path = Path()
        if let f = top.first {
            path.move(to: f)
            top.dropFirst().forEach { path.addLine(to: $0) }
            bottom.reversed().forEach { path.addLine(to: $0) }
            path.closeSubpath()
            context.fill(path, with: .color(KSTheme.waveformBlue.opacity(0.45)))
        }
    }

    private func drawZones(context: inout GraphicsContext, plot: CGRect) {
        for zone in currentZones {
            let x0 = xPosition(forTime: zone.start, plot: plot)
            let x1 = xPosition(forTime: zone.end, plot: plot)
            let rect = CGRect(x: min(x0, x1), y: plot.minY, width: max(4, abs(x1 - x0)), height: plot.height)
            let selected = zone.id == selectedZoneID
            context.fill(Path(rect), with: .color(Color.red.opacity(selected ? 0.40 : 0.26)))
            context.stroke(Path(rect), with: .color(Color.red.opacity(0.9)), lineWidth: selected ? 2.2 : 1)
            let handleW: CGFloat = 5
            context.fill(
                Path(CGRect(x: rect.minX, y: plot.minY, width: handleW, height: plot.height)),
                with: .color(.red.opacity(0.95))
            )
            context.fill(
                Path(CGRect(x: rect.maxX - handleW, y: plot.minY, width: handleW, height: plot.height)),
                with: .color(.red.opacity(0.95))
            )
        }
    }

    private func drawPlayhead(context: inout GraphicsContext, plot: CGRect) {
        guard duration > 0, player.playingPath == currentTrack?.sourcePath else { return }
        let t = player.currentTime
        // Don't draw playhead inside exclusion (already skipped).
        if currentZones.contains(where: { t >= $0.start && t < $0.end }) { return }
        let px = xPosition(forTime: t, plot: plot)
        var line = Path()
        line.move(to: CGPoint(x: px, y: plot.minY))
        line.addLine(to: CGPoint(x: px, y: plot.maxY))
        context.stroke(line, with: .color(KSTheme.playheadAmber), lineWidth: 1.5)
    }

    // MARK: - Gestures

    private func zoneDragGesture(plot: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .onChanged { value in
                handleDragChanged(value, plot: plot)
            }
            .onEnded { value in
                handleDragEnded(value, plot: plot)
            }
    }

    private func handleDragChanged(_ value: DragGesture.Value, plot: CGRect) {
        guard let trackID = currentTrackID, duration > 0 else { return }
        let forceCreate = NSEvent.modifierFlags.contains(.shift)
        let t0 = time(atX: value.startLocation.x, plot: plot)
        let t1 = time(atX: value.location.x, plot: plot)

        if dragMode == .none {
            if forceCreate {
                beginCreate(t0: t0, t1: t1, trackID: trackID)
                return
            }
            if let hit = hitTest(x: value.startLocation.x, plot: plot) {
                selectedZoneID = hit.zone.id
                dragOriginalZone = hit.zone
                dragMode = hit.edge
            } else {
                beginCreate(t0: t0, t1: t1, trackID: trackID)
            }
            return
        }

        guard var original = dragOriginalZone else { return }
        let base = dragOriginalZone!
        let startT = time(atX: value.startLocation.x, plot: plot)
        let curT = time(atX: value.location.x, plot: plot)
        let delta = curT - startT

        switch dragMode {
        case .create:
            original = AutomationTimeRange(id: original.id, start: t0, end: t1)
        case .move:
            let width = base.end - base.start
            var ns = base.start + delta
            ns = min(max(0, ns), max(0, duration - width))
            original = AutomationTimeRange(id: base.id, start: ns, end: ns + width)
        case .resizeLeft:
            var ns = base.start + delta
            ns = min(max(0, ns), base.end - 0.05)
            original = AutomationTimeRange(id: base.id, start: ns, end: base.end)
        case .resizeRight:
            var ne = base.end + delta
            ne = max(min(duration, ne), base.start + 0.05)
            original = AutomationTimeRange(id: base.id, start: base.start, end: ne)
        case .none:
            break
        }

        replaceZone(original, trackID: trackID)
        selectedZoneID = original.id
    }

    private func beginCreate(t0: Double, t1: Double, trackID: UUID) {
        dragMode = .create
        let zone = AutomationTimeRange(start: t0, end: t1)
        selectedZoneID = zone.id
        dragOriginalZone = zone
        var zones = currentZones
        zones.append(zone)
        store.updateZones(for: trackID, zones: zones, propagateToAllSelected: true)
    }

    private func replaceZone(_ zone: AutomationTimeRange, trackID: UUID) {
        var zones = currentZones.filter { $0.id != zone.id }
        zones.append(zone)
        store.updateZones(for: trackID, zones: zones, propagateToAllSelected: true)
    }

    private func handleDragEnded(_ value: DragGesture.Value, plot: CGRect) {
        // Short click: select zone under cursor or seek
        if hypot(value.translation.width, value.translation.height) < 4 {
            if let hit = hitTest(x: value.startLocation.x, plot: plot) {
                selectedZoneID = hit.zone.id
            } else if let path = currentTrack?.sourcePath, duration > 0 {
                let t = time(atX: value.startLocation.x, plot: plot)
                // Don't seek into exclusion — jump to end of covering zone
                let seekT = skipTimeIfInsideZone(t)
                player.seek(path: path, time: seekT)
                selectedZoneID = nil
            }
        }
        if let trackID = currentTrackID {
            store.updateZones(for: trackID, zones: currentZones, propagateToAllSelected: true)
        }
        dragMode = .none
        dragOriginalZone = nil
    }

    private struct ZoneHit {
        var zone: AutomationTimeRange
        var edge: ZoneDragMode
    }

    private func hitTest(x: CGFloat, plot: CGRect) -> ZoneHit? {
        let handle: CGFloat = 8
        for zone in currentZones.reversed() {
            let x0 = xPosition(forTime: zone.start, plot: plot)
            let x1 = xPosition(forTime: zone.end, plot: plot)
            let left = min(x0, x1)
            let right = max(x0, x1)
            if abs(x - left) <= handle { return ZoneHit(zone: zone, edge: .resizeLeft) }
            if abs(x - right) <= handle { return ZoneHit(zone: zone, edge: .resizeRight) }
            if x >= left && x <= right { return ZoneHit(zone: zone, edge: .move) }
        }
        return nil
    }

    private func deleteSelectedZone() {
        guard let trackID = currentTrackID, let sid = selectedZoneID else { return }
        let zones = currentZones.filter { $0.id != sid }
        store.updateZones(for: trackID, zones: zones, propagateToAllSelected: true)
        selectedZoneID = nil
    }

    // MARK: - Playback

    private func togglePlayback() {
        guard let path = currentTrack?.sourcePath else { return }
        // If starting inside a zone, jump out first
        if !player.isPlaying || player.playingPath != path {
            let t = skipTimeIfInsideZone(player.playingPath == path ? player.currentTime : 0)
            player.seek(path: path, time: t)
        }
        player.toggle(path: path)
    }

    private func skipTimeIfInsideZone(_ t: Double) -> Double {
        for zone in currentZones.sorted(by: { $0.start < $1.start }) {
            if t >= zone.start && t < zone.end {
                return min(duration, zone.end + 0.001)
            }
        }
        return t
    }

    private func skipPlaybackThroughZonesIfNeeded() {
        guard isPlaying, duration > 0 else { return }
        let t = player.currentTime
        for zone in currentZones {
            // Jump as soon as we enter the zone — never play inside.
            if t + 0.01 >= zone.start && t < zone.end {
                if let path = currentTrack?.sourcePath {
                    player.seek(path: path, time: min(duration, zone.end + 0.001))
                }
                return
            }
        }
    }

    private func loadAnalysisForCurrentTrack() async {
        guard let track = currentTrack else {
            analysis = nil
            return
        }
        isAnalyzing = true
        analysisError = nil
        analysis = nil
        viewport.reset()
        selectedZoneID = nil
        do {
            let result = try await backend.analyzeAudio(url: track.sourceURL)
            analysis = result
            if let index = store.job.tracks.firstIndex(where: { $0.id == track.id }) {
                store.job.tracks[index].durationSeconds = result.durationSeconds
            }
        } catch {
            analysisError = error.localizedDescription
        }
        isAnalyzing = false
    }
}
