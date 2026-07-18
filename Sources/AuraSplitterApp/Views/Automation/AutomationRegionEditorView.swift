import AppKit
import SwiftUI

/// Step 2: preview player + exclusion zones (semi-transparent red ranges to remove).
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
    @State private var dragStartX: CGFloat = 0
    @State private var dragOriginalZone: AutomationTimeRange?

    private enum ZoneDragMode {
        case none
        case create
        case move
        case resizeLeft
        case resizeRight
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
                    .frame(maxWidth: 260)
                }
            }

            Text("Drag on the timeline to mark parts to remove (other singers, noise). Drag edges to trim. Shift+drag adds another zone. Playback skips red zones.")
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
                Button("Clear zones") {
                    if let id = currentTrackID {
                        store.updateZones(for: id, zones: [])
                        selectedZoneID = nil
                    }
                }
                .controlSize(.small)
                .disabled(currentZones.isEmpty)

                Button("Copy zones to all selected tracks") {
                    if let id = currentTrackID {
                        store.copyZonesToAllSelectedTracks(from: id)
                    }
                }
                .controlSize(.small)
                .disabled(currentTrackID == nil)

                Spacer()
                Text("\(currentZones.count) zone(s)")
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
        .onReceive(Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()) { _ in
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
        analysis?.durationSeconds ?? player.duration
    }

    private var isPlaying: Bool {
        guard let path = currentTrack?.sourcePath else { return false }
        return player.playingPath == path && player.isPlaying
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button {
                guard let path = currentTrack?.sourcePath else { return }
                player.toggle(path: path)
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .disabled(currentTrack == nil || analysis == nil)

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

            Spacer()

            if selectedZoneID != nil {
                Button(role: .destructive) {
                    deleteSelectedZone()
                } label: {
                    Label("Delete zone", systemImage: "trash")
                }
                .controlSize(.small)
            }
        }
    }

    private var timeLabel: String {
        let t = player.playingPath == currentTrack?.sourcePath ? player.currentTime : 0
        let d = duration
        return "\(FileHelpers.formattedTimestamp(t)) / \(FileHelpers.formattedTimestamp(d))"
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

                // Interaction layer
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(timelineDragGesture(plot: plot, size: geo.size))
                    .onTapGesture(count: 1) { location in
                        // handled via drag for precision; optional seek on short click below
                    }
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0)
                            .onEnded { value in
                                if hypot(value.translation.width, value.translation.height) < 4,
                                   duration > 0 {
                                    let t = time(atX: value.location.x, plot: plot)
                                    if let path = currentTrack?.sourcePath {
                                        player.seek(path: path, time: t)
                                    }
                                }
                            }
                    )
            }
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
            // Outside viewport — clamp to edges
            if absFrac < viewport.start { return plot.minX }
            return plot.maxX
        }
        return plot.minX + CGFloat(vis) * plot.width
    }

    // MARK: - Drawing

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
            context.fill(Path(rect), with: .color(Color.red.opacity(selected ? 0.38 : 0.26)))
            context.stroke(Path(rect), with: .color(Color.red.opacity(0.85)), lineWidth: selected ? 2 : 1)
            // Edge handles
            let handleW: CGFloat = 4
            context.fill(Path(CGRect(x: rect.minX, y: plot.minY, width: handleW, height: plot.height)), with: .color(.red.opacity(0.9)))
            context.fill(Path(CGRect(x: rect.maxX - handleW, y: plot.minY, width: handleW, height: plot.height)), with: .color(.red.opacity(0.9)))
        }
    }

    private func drawPlayhead(context: inout GraphicsContext, plot: CGRect) {
        guard duration > 0, player.playingPath == currentTrack?.sourcePath else { return }
        let px = xPosition(forTime: player.currentTime, plot: plot)
        var line = Path()
        line.move(to: CGPoint(x: px, y: plot.minY))
        line.addLine(to: CGPoint(x: px, y: plot.maxY))
        context.stroke(line, with: .color(KSTheme.playheadAmber), lineWidth: 1.5)
    }

    // MARK: - Gestures

    private func timelineDragGesture(plot: CGRect, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .local)
            .onChanged { value in
                let forceCreate = NSEvent.modifierFlags.contains(.shift)
                handleDragChanged(value, plot: plot, forceCreate: forceCreate)
            }
            .onEnded { value in
                handleDragEnded(value, plot: plot)
            }
    }

    private func handleDragChanged(_ value: DragGesture.Value, plot: CGRect, forceCreate: Bool) {
        guard let trackID = currentTrackID, duration > 0 else { return }
        let t0 = time(atX: value.startLocation.x, plot: plot)
        let t1 = time(atX: value.location.x, plot: plot)

        if dragMode == .none {
            dragStartX = value.startLocation.x
            if forceCreate {
                dragMode = .create
                let zone = AutomationTimeRange(start: t0, end: t1)
                selectedZoneID = zone.id
                dragOriginalZone = zone
                var zones = currentZones
                zones.append(zone)
                store.updateZones(for: trackID, zones: zones)
                return
            }
            // Hit-test existing zone
            if let hit = hitTest(x: value.startLocation.x, plot: plot) {
                selectedZoneID = hit.zone.id
                dragOriginalZone = hit.zone
                dragMode = hit.edge
            } else {
                dragMode = .create
                let zone = AutomationTimeRange(start: t0, end: t1)
                selectedZoneID = zone.id
                dragOriginalZone = zone
                var zones = currentZones
                zones.append(zone)
                store.updateZones(for: trackID, zones: zones)
            }
            return
        }

        guard var original = dragOriginalZone else { return }
        switch dragMode {
        case .create:
            original = AutomationTimeRange(id: original.id, start: t0, end: t1)
        case .move:
            let base = dragOriginalZone!
            let width = base.end - base.start
            let startT = time(atX: value.startLocation.x, plot: plot)
            let curT = time(atX: value.location.x, plot: plot)
            let delta = curT - startT
            var ns = base.start + delta
            ns = min(max(0, ns), max(0, duration - width))
            original = AutomationTimeRange(id: base.id, start: ns, end: ns + width)
        case .resizeLeft:
            let base = dragOriginalZone!
            let startT = time(atX: value.startLocation.x, plot: plot)
            let curT = time(atX: value.location.x, plot: plot)
            let delta = curT - startT
            var ns = base.start + delta
            ns = min(max(0, ns), base.end - 0.05)
            original = AutomationTimeRange(id: base.id, start: ns, end: base.end)
        case .resizeRight:
            let base = dragOriginalZone!
            let startT = time(atX: value.startLocation.x, plot: plot)
            let curT = time(atX: value.location.x, plot: plot)
            let delta = curT - startT
            var ne = base.end + delta
            ne = max(min(duration, ne), base.start + 0.05)
            original = AutomationTimeRange(id: base.id, start: base.start, end: ne)
        case .none:
            break
        }

        var zones = currentZones.filter { $0.id != original.id }
        zones.append(original)
        store.updateZones(for: trackID, zones: zones)
        selectedZoneID = original.id
    }

    private func handleDragEnded(_ value: DragGesture.Value, plot: CGRect) {
        dragMode = .none
        dragOriginalZone = nil
        if let trackID = currentTrackID {
            // Normalize / merge
            store.updateZones(for: trackID, zones: currentZones)
        }
    }

    private struct ZoneHit {
        var zone: AutomationTimeRange
        var edge: ZoneDragMode // move / resizeLeft / resizeRight
    }

    private func hitTest(x: CGFloat, plot: CGRect) -> ZoneHit? {
        let handle: CGFloat = 8
        for zone in currentZones.reversed() {
            let x0 = xPosition(forTime: zone.start, plot: plot)
            let x1 = xPosition(forTime: zone.end, plot: plot)
            let left = min(x0, x1)
            let right = max(x0, x1)
            if abs(x - left) <= handle {
                return ZoneHit(zone: zone, edge: .resizeLeft)
            }
            if abs(x - right) <= handle {
                return ZoneHit(zone: zone, edge: .resizeRight)
            }
            if x >= left && x <= right {
                return ZoneHit(zone: zone, edge: .move)
            }
        }
        return nil
    }

    private func deleteSelectedZone() {
        guard let trackID = currentTrackID, let sid = selectedZoneID else { return }
        let zones = currentZones.filter { $0.id != sid }
        store.updateZones(for: trackID, zones: zones)
        selectedZoneID = nil
    }

    // MARK: - Analysis + playback skip

    private func loadAnalysisForCurrentTrack() async {
        guard let track = currentTrack else {
            analysis = nil
            return
        }
        isAnalyzing = true
        analysisError = nil
        analysis = nil
        viewport.reset()
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

    private func skipPlaybackThroughZonesIfNeeded() {
        guard isPlaying, duration > 0 else { return }
        let t = player.currentTime
        for zone in currentZones {
            if t >= zone.start && t < zone.end - 0.02 {
                if let path = currentTrack?.sourcePath {
                    player.seek(path: path, time: zone.end)
                }
                break
            }
        }
    }
}
