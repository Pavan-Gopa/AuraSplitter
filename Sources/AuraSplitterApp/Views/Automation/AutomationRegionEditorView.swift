import AppKit
import SwiftUI

/// Regions: spectrogram + waveform, ⌘-drag add cut zones, ⌃/⌥-drag subtract, click playhead.
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
    /// Local playhead so it always redraws after click even before AV engine reports path.
    @State private var playheadSeconds: Double = 0

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

            Text("⌘-drag: add red cut · ⌃/⌥-drag (or right-drag): erase · click: playhead outside cuts · scroll: zoom · Shift-scroll / ⌥-drag: pan · Space: play. Zones apply to all selected tracks.")
                .font(.caption)
                .foregroundStyle(.secondary)

            toolbar

            ZStack {
                KSTheme.canvasBackground
                timelineContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
            )

            HStack {
                Button("CLEAR") {
                    if let id = currentTrackID {
                        store.clearZones(for: id)
                        selectedZoneID = nil
                    }
                }
                .controlSize(.small)
                .disabled(currentZones.isEmpty)

                if selectedZoneID != nil {
                    Button(role: .destructive) {
                        deleteSelectedZone()
                    } label: {
                        Label("Delete zone", systemImage: "trash")
                    }
                    .controlSize(.small)
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
        .onDisappear { player.stop() }
        // Drive playhead only while playing — a permanent 30 Hz timer keeps the whole
        // wizard view graph warm even after leaving Regions / when idle.
        .onReceive(
            Timer.publish(every: 0.03, on: .main, in: .common).autoconnect(),
            perform: { _ in
                guard isPlaying else { return }
                syncPlayheadFromPlayer()
                skipPlaybackThroughZonesIfNeeded()
            }
        )
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

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button(action: togglePlayback) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .disabled(currentTrack == nil)
            .keyboardShortcut(.space, modifiers: [])
            .help("Play / pause (Space)")

            Text("\(FileHelpers.formattedTimestamp(playheadSeconds)) / \(FileHelpers.formattedTimestamp(duration))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            if isAnalyzing {
                ProgressView().controlSize(.small)
                Text("Analyzing…").font(.caption).foregroundStyle(.secondary)
            }
            if let analysisError {
                Text(analysisError).font(.caption2).foregroundStyle(.red).lineLimit(1)
            }

            if viewport.isZoomed {
                Button { viewport.reset() } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.borderless)
                .help("Fit full duration")

                Text(String(format: "%.1fx", viewport.zoomFactor))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Timeline

    private var timelineContent: some View {
        GeometryReader { geo in
            let plot = plotRect(in: geo.size)
            ZStack {
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

                AutomationTimelineInteractionView(
                    duration: duration,
                    viewport: viewport,
                    zones: currentZones,
                    selectedZoneID: selectedZoneID,
                    onViewportChange: { viewport = $0 },
                    onSelectedZoneChange: { selectedZoneID = $0 },
                    onZonesChange: { newZones in
                        guard let id = currentTrackID else { return }
                        store.updateZones(for: id, zones: newZones, propagateToAllSelected: true)
                    },
                    onSeek: { t in
                        placePlayhead(at: t)
                    },
                    onSpacebar: togglePlayback
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func plotRect(in size: CGSize) -> CGRect {
        CGRect(x: 12, y: 12, width: max(1, size.width - 24), height: max(1, size.height - 24))
    }

    private func xPosition(forTime t: Double, plot: CGRect) -> CGFloat {
        guard duration > 0 else { return plot.minX }
        let absFrac = min(1, max(0, t / duration))
        guard let vis = viewport.visibleFraction(forAbsoluteFraction: absFrac) else {
            return absFrac < viewport.start ? plot.minX : plot.maxX
        }
        return plot.minX + CGFloat(vis) * plot.width
    }

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
            context.fill(Path(rect), with: .color(Color.red.opacity(selected ? 0.42 : 0.28)))
            context.stroke(Path(rect), with: .color(Color.red.opacity(0.9)), lineWidth: selected ? 2.2 : 1)
            let handleW: CGFloat = 5
            context.fill(Path(CGRect(x: rect.minX, y: plot.minY, width: handleW, height: plot.height)), with: .color(.red))
            context.fill(Path(CGRect(x: rect.maxX - handleW, y: plot.minY, width: handleW, height: plot.height)), with: .color(.red))
        }
    }

    private func drawPlayhead(context: inout GraphicsContext, plot: CGRect) {
        guard duration > 0 else { return }
        let t = playheadSeconds
        // Never draw playhead inside a cut zone.
        if currentZones.contains(where: { t >= $0.start && t < $0.end }) { return }
        let px = xPosition(forTime: t, plot: plot)
        var line = Path()
        line.move(to: CGPoint(x: px, y: plot.minY))
        line.addLine(to: CGPoint(x: px, y: plot.maxY))
        context.stroke(line, with: .color(KSTheme.playheadAmber), lineWidth: 1.5)
        context.fill(
            Path(ellipseIn: CGRect(x: px - 4, y: plot.minY - 4, width: 8, height: 8)),
            with: .color(KSTheme.playheadAmber)
        )
    }

    // MARK: - Playback helpers

    private func placePlayhead(at t: Double) {
        guard let path = currentTrack?.sourcePath, duration > 0 else { return }
        // Playhead only outside red zones — jump just past if click lands inside.
        var target = min(max(0, t), duration)
        if let zone = currentZones.first(where: { target >= $0.start && target < $0.end }) {
            target = min(duration, zone.end + 0.001)
        }
        playheadSeconds = target
        player.seek(path: path, time: target)
    }

    private func syncPlayheadFromPlayer() {
        guard let path = currentTrack?.sourcePath, player.playingPath == path else { return }
        // Only pull from player while playing so a manual seek isn't overwritten before load.
        if player.isPlaying {
            playheadSeconds = player.currentTime
        }
    }

    private func togglePlayback() {
        guard let path = currentTrack?.sourcePath else { return }
        if !player.isPlaying || player.playingPath != path {
            let t = skipTimeIfInsideZone(playheadSeconds)
            playheadSeconds = t
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
            if t + 0.005 >= zone.start && t < zone.end {
                if let path = currentTrack?.sourcePath {
                    let next = min(duration, zone.end + 0.001)
                    playheadSeconds = next
                    player.seek(path: path, time: next)
                }
                return
            }
        }
    }

    private func deleteSelectedZone() {
        guard let trackID = currentTrackID, let sid = selectedZoneID else { return }
        store.updateZones(
            for: trackID,
            zones: currentZones.filter { $0.id != sid },
            propagateToAllSelected: true
        )
        selectedZoneID = nil
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
        playheadSeconds = 0
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

// MARK: - NSView interaction (Cmd / Ctrl / zoom / pan / Space)

private struct AutomationTimelineInteractionView: NSViewRepresentable {
    var duration: Double
    var viewport: AudioPreviewViewport
    var zones: [AutomationTimeRange]
    var selectedZoneID: UUID?
    var onViewportChange: (AudioPreviewViewport) -> Void
    var onSelectedZoneChange: (UUID?) -> Void
    var onZonesChange: ([AutomationTimeRange]) -> Void
    var onSeek: (Double) -> Void
    var onSpacebar: () -> Void

    func makeNSView(context: Context) -> AutomationTimelineNSView {
        let view = AutomationTimelineNSView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: AutomationTimelineNSView, context: Context) {
        context.coordinator.parent = self
        nsView.coordinator = context.coordinator
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator {
        var parent: AutomationTimelineInteractionView
        var dragMode: DragMode = .none
        var dragOriginal: AutomationTimeRange?
        var dragStartTime: Double = 0
        var lastPanPoint: CGPoint?

        enum DragMode {
            case none, create, subtract, move, resizeLeft, resizeRight, pan
        }

        init(_ parent: AutomationTimelineInteractionView) {
            self.parent = parent
        }

        func plot(in size: CGSize) -> CGRect {
            CGRect(x: 12, y: 12, width: max(1, size.width - 24), height: max(1, size.height - 24))
        }

        func time(at x: CGFloat, size: CGSize) -> Double {
            let plot = plot(in: size)
            guard plot.width > 0, parent.duration > 0 else { return 0 }
            let frac = min(1, max(0, Double((x - plot.minX) / plot.width)))
            return parent.viewport.absoluteFraction(forVisibleFraction: frac) * parent.duration
        }
    }
}

private final class AutomationTimelineNSView: NSView {
    weak var coordinator: AutomationTimelineInteractionView.Coordinator?
    private var spaceMonitor: Any?
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    deinit {
        if let spaceMonitor {
            NSEvent.removeMonitor(spaceMonitor)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let spaceMonitor {
            NSEvent.removeMonitor(spaceMonitor)
            self.spaceMonitor = nil
        }
        if window != nil {
            DispatchQueue.main.async { [weak self] in
                self?.window?.makeFirstResponder(self)
            }
            // Backup Space handler when another control steals first responder.
            spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.window?.isKeyWindow == true else { return event }
                // Only when mouse is over this timeline (or we are first responder).
                let overSelf: Bool = {
                    guard let w = self.window else { return false }
                    let loc = w.mouseLocationOutsideOfEventStream
                    let p = self.convert(loc, from: nil)
                    return self.bounds.contains(p)
                }()
                if event.keyCode == 49, !event.isARepeat, overSelf || self.window?.firstResponder === self {
                    // Don't steal Space from text fields.
                    if self.window?.firstResponder is NSTextView { return event }
                    self.coordinator?.parent.onSpacebar()
                    return nil
                }
                return event
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let c = coordinator else { return }
        let p = convert(event.locationInWindow, from: nil)
        let t = c.time(at: p.x, size: bounds.size)
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let plot = c.plot(in: bounds.size)

        // ⌥-drag without zone hit → pan (trackpad-friendly; no middle button needed)
        if mods.contains(.option) && !mods.contains(.command) && !mods.contains(.control) {
            // If option alone, prefer pan when zoomed; if not zoomed still allow for consistency.
            c.dragMode = .pan
            c.lastPanPoint = p
            NSCursor.closedHand.push()
            return
        }

        if mods.contains(.command) {
            // ⌘-drag: add zone
            c.dragMode = .create
            c.dragStartTime = t
            let zone = AutomationTimeRange(start: t, end: t)
            c.dragOriginal = zone
            c.parent.onSelectedZoneChange(zone.id)
            var zones = c.parent.zones
            zones.append(zone)
            c.parent.onZonesChange(zones)
            return
        }

        // ⌃ is often remapped; also treat control flag if present on left button.
        if mods.contains(.control) {
            c.dragMode = .subtract
            c.dragStartTime = t
            c.dragOriginal = AutomationTimeRange(start: t, end: t)
            return
        }

        // Hit-test zone for move/resize
        if let hit = hitTestZone(
            x: p.x,
            plot: plot,
            zones: c.parent.zones,
            viewport: c.parent.viewport,
            duration: c.parent.duration
        ) {
            c.parent.onSelectedZoneChange(hit.zone.id)
            c.dragOriginal = hit.zone
            c.dragStartTime = t
            c.dragMode = hit.mode
            return
        }

        // Plain click: playhead (outside zones only — onSeek jumps past cuts)
        c.dragMode = .none
        c.parent.onSelectedZoneChange(nil)
        c.parent.onSeek(t)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let c = coordinator, c.dragMode != .none else { return }
        let p = convert(event.locationInWindow, from: nil)
        let t = c.time(at: p.x, size: bounds.size)
        let d = max(0, c.parent.duration)

        switch c.dragMode {
        case .create:
            guard let orig = c.dragOriginal else { return }
            let zone = AutomationTimeRange(id: orig.id, start: c.dragStartTime, end: t)
            c.parent.onSelectedZoneChange(zone.id)
            var zones = c.parent.zones.filter { $0.id != zone.id }
            zones.append(zone)
            c.parent.onZonesChange(zones)

        case .subtract:
            c.dragOriginal = AutomationTimeRange(start: c.dragStartTime, end: t)

        case .move:
            guard let base = c.dragOriginal else { return }
            let width = base.end - base.start
            let delta = t - c.dragStartTime
            var ns = base.start + delta
            ns = min(max(0, ns), max(0, d - width))
            let zone = AutomationTimeRange(id: base.id, start: ns, end: ns + width)
            var zones = c.parent.zones.filter { $0.id != zone.id }
            zones.append(zone)
            c.parent.onZonesChange(zones)

        case .resizeLeft:
            guard let base = c.dragOriginal else { return }
            let delta = t - c.dragStartTime
            var ns = base.start + delta
            ns = min(max(0, ns), base.end - 0.05)
            let zone = AutomationTimeRange(id: base.id, start: ns, end: base.end)
            var zones = c.parent.zones.filter { $0.id != zone.id }
            zones.append(zone)
            c.parent.onZonesChange(zones)

        case .resizeRight:
            guard let base = c.dragOriginal else { return }
            let delta = t - c.dragStartTime
            var ne = base.end + delta
            ne = max(min(d, ne), base.start + 0.05)
            let zone = AutomationTimeRange(id: base.id, start: base.start, end: ne)
            var zones = c.parent.zones.filter { $0.id != zone.id }
            zones.append(zone)
            c.parent.onZonesChange(zones)

        case .pan:
            if let prev = c.lastPanPoint {
                var vp = c.parent.viewport
                vp.pan(deltaX: Double(p.x - prev.x), canvasWidth: Double(max(1, bounds.width)))
                c.parent.onViewportChange(vp)
            }
            c.lastPanPoint = p

        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let c = coordinator else { return }
        if c.dragMode == .subtract, let cut = c.dragOriginal {
            let remaining = subtractRange(cut, from: c.parent.zones)
            c.parent.onZonesChange(remaining)
            c.parent.onSelectedZoneChange(nil)
        }
        if c.dragMode == .create {
            // Drop zero-width marks; merge overlaps.
            let merged = AutomationTimeRange.merge(c.parent.zones)
            c.parent.onZonesChange(merged)
        }
        if c.dragMode == .pan {
            NSCursor.pop()
        }
        c.dragMode = .none
        c.dragOriginal = nil
        c.lastPanPoint = nil
    }

    // Control-click on macOS arrives as rightMouse*; also support right-drag as subtract.
    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let c = coordinator else { return }
        let p = convert(event.locationInWindow, from: nil)
        let t = c.time(at: p.x, size: bounds.size)
        c.dragMode = .subtract
        c.dragStartTime = t
        c.dragOriginal = AutomationTimeRange(start: t, end: t)
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard let c = coordinator, c.dragMode == .subtract else { return }
        let p = convert(event.locationInWindow, from: nil)
        let t = c.time(at: p.x, size: bounds.size)
        c.dragOriginal = AutomationTimeRange(start: c.dragStartTime, end: t)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let c = coordinator else { return }
        if c.dragMode == .subtract, let cut = c.dragOriginal {
            let remaining = subtractRange(cut, from: c.parent.zones)
            c.parent.onZonesChange(remaining)
            c.parent.onSelectedZoneChange(nil)
        }
        c.dragMode = .none
        c.dragOriginal = nil
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2, let c = coordinator else {
            super.otherMouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        c.dragMode = .pan
        c.lastPanPoint = convert(event.locationInWindow, from: nil)
        NSCursor.closedHand.push()
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard event.buttonNumber == 2, let c = coordinator, c.dragMode == .pan else {
            super.otherMouseDragged(with: event)
            return
        }
        let cur = convert(event.locationInWindow, from: nil)
        if let prev = c.lastPanPoint {
            var vp = c.parent.viewport
            vp.pan(deltaX: Double(cur.x - prev.x), canvasWidth: Double(max(1, bounds.width)))
            c.parent.onViewportChange(vp)
        }
        c.lastPanPoint = cur
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2, let c = coordinator else {
            super.otherMouseUp(with: event)
            return
        }
        if c.dragMode == .pan {
            NSCursor.pop()
        }
        c.dragMode = .none
        c.lastPanPoint = nil
    }

    override func scrollWheel(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let c = coordinator else { return }
        let p = convert(event.locationInWindow, from: nil)
        let plot = c.plot(in: bounds.size)
        let anchor = min(1, max(0, Double((p.x - plot.minX) / max(1, plot.width))))
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Shift-scroll or pure horizontal scroll → pan when zoomed.
        let horizontalDominant = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        if mods.contains(.shift) || (horizontalDominant && c.parent.viewport.isZoomed) {
            var vp = c.parent.viewport
            let delta = horizontalDominant ? event.scrollingDeltaX : event.scrollingDeltaY
            // Invert so finger direction matches content.
            vp.pan(deltaX: Double(delta), canvasWidth: Double(max(1, plot.width)))
            c.parent.onViewportChange(vp)
            return
        }

        let delta = abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX)
            ? event.scrollingDeltaY
            : event.scrollingDeltaX
        guard delta != 0 else { return }
        var vp = c.parent.viewport
        vp.zoom(deltaY: Double(delta), anchorFraction: anchor)
        c.parent.onViewportChange(vp)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 { // space
            coordinator?.parent.onSpacebar()
            return
        }
        if event.keyCode == 51 || event.keyCode == 117, let sid = coordinator?.parent.selectedZoneID {
            let zones = coordinator?.parent.zones.filter { $0.id != sid } ?? []
            coordinator?.parent.onZonesChange(zones)
            coordinator?.parent.onSelectedZoneChange(nil)
            return
        }
        super.keyDown(with: event)
    }

    private struct Hit {
        var zone: AutomationTimeRange
        var mode: AutomationTimelineInteractionView.Coordinator.DragMode
    }

    private func hitTestZone(
        x: CGFloat,
        plot: CGRect,
        zones: [AutomationTimeRange],
        viewport: AudioPreviewViewport,
        duration: Double
    ) -> Hit? {
        let handle: CGFloat = 8
        for zone in zones.reversed() {
            let x0 = xPos(zone.start, plot: plot, viewport: viewport, duration: duration)
            let x1 = xPos(zone.end, plot: plot, viewport: viewport, duration: duration)
            let left = min(x0, x1)
            let right = max(x0, x1)
            if abs(x - left) <= handle { return Hit(zone: zone, mode: .resizeLeft) }
            if abs(x - right) <= handle { return Hit(zone: zone, mode: .resizeRight) }
            if x >= left && x <= right { return Hit(zone: zone, mode: .move) }
        }
        return nil
    }

    private func xPos(_ t: Double, plot: CGRect, viewport: AudioPreviewViewport, duration: Double) -> CGFloat {
        guard duration > 0 else { return plot.minX }
        let absFrac = min(1, max(0, t / duration))
        guard let vis = viewport.visibleFraction(forAbsoluteFraction: absFrac) else {
            return absFrac < viewport.start ? plot.minX : plot.maxX
        }
        return plot.minX + CGFloat(vis) * plot.width
    }

    /// Remove `cut` interval from zone list (split as needed).
    private func subtractRange(_ cut: AutomationTimeRange, from zones: [AutomationTimeRange]) -> [AutomationTimeRange] {
        let c = AutomationTimeRange(start: min(cut.start, cut.end), end: max(cut.start, cut.end))
        guard c.isValid else { return zones }
        var result: [AutomationTimeRange] = []
        for z in zones {
            if c.end <= z.start || c.start >= z.end {
                result.append(z)
                continue
            }
            if c.start > z.start + 0.02 {
                result.append(AutomationTimeRange(start: z.start, end: c.start))
            }
            if c.end < z.end - 0.02 {
                result.append(AutomationTimeRange(start: c.end, end: z.end))
            }
        }
        return AutomationTimeRange.merge(result)
    }
}
