import AppKit
import SwiftUI

/// Multi-step Automation: Input/Output → Regions → Matrix (+ Process).
struct AutomationWizardView: View {
    @ObservedObject var backend: BackendClient
    @ObservedObject var processPresetStore: ProcessSettingsPresetStore
    @ObservedObject private var menuVisibility = MenuVisibilityStore.shared
    @StateObject private var store: AutomationWizardStore
    /// User star ratings (1…3) from the main model menu; shown on Matrix headers.
    var modelRatings: [String: Int]
    /// Sync process preset back to the main app header when changed in Matrix.
    var onProcessPresetChange: ((String) -> Void)?
    let onClose: () -> Void

    init(
        backend: BackendClient,
        processPresetStore: ProcessSettingsPresetStore,
        processPresetID: String,
        processSettings: SeparationSettings,
        modelRatings: [String: Int] = [:],
        onProcessPresetChange: ((String) -> Void)? = nil,
        onClose: @escaping () -> Void
    ) {
        self.backend = backend
        self.processPresetStore = processPresetStore
        _store = StateObject(
            wrappedValue: AutomationWizardStore(
                processPresetID: processPresetID,
                processSettings: processSettings
            )
        )
        // ContentView passes live ratings; fall back to UserDefaults if empty.
        if modelRatings.isEmpty {
            self.modelRatings =
                (UserDefaults.standard.dictionary(forKey: "KirtanSplitter.modelRatings") as? [String: Int]) ?? [:]
        } else {
            self.modelRatings = modelRatings
        }
        self.onProcessPresetChange = onProcessPresetChange
        self.onClose = onClose
    }

    @State private var isMatrixFullscreen = false
    /// Exact sheet geometry before expand — restored bit-for-bit on collapse.
    @State private var preExpandWindowFrame: NSRect?
    @State private var preExpandMinSize: NSSize?
    @State private var preExpandMaxSize: NSSize?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            stepBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        // Keep ideal size STABLE across fullscreen toggle. Changing idealWidth/Height
        // was overriding the restored NSWindow frame and leaving a different sheet size.
        .frame(minWidth: 960, idealWidth: 1000, maxWidth: .infinity,
               minHeight: 640, idealHeight: 720, maxHeight: .infinity)
        .background(KSTheme.panelBackground)
        .background(
            MatrixWindowSizer(
                isFullscreen: isMatrixFullscreen && store.step == .matrix,
                preExpandFrame: preExpandWindowFrame
            )
        )
        .onChange(of: store.step) { step in
            if step != .matrix, isMatrixFullscreen {
                collapseMatrixFullscreen(animated: false)
            }
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Automation")
                    .font(.title2.weight(.semibold))
                Text("Input/Output → Regions → Matrix → Ready MIX")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            stepIndicator
            if store.step == .matrix {
                Button {
                    toggleMatrixFullscreen()
                } label: {
                    Image(systemName: isMatrixFullscreen
                          ? "arrow.down.right.and.arrow.up.left"
                          : "arrow.up.left.and.arrow.down.right")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(isMatrixFullscreen ? "Exit full screen" : "Expand Matrix to full screen")
            }
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var stepIndicator: some View {
        HStack(spacing: 10) {
            ForEach(AutomationWizardStep.allCases) { step in
                HStack(spacing: 5) {
                    Circle()
                        .fill(stepFill(step))
                        .frame(width: 8, height: 8)
                    Text(step.title)
                        .font(.caption.weight(store.step == step ? .semibold : .regular))
                        .foregroundStyle(store.step == step ? .primary : .secondary)
                }
                if step != .matrix {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func stepFill(_ step: AutomationWizardStep) -> Color {
        if step == store.step { return KSTheme.accent }
        if step < store.step { return KSTheme.accent.opacity(0.45) }
        return Color.secondary.opacity(0.35)
    }

    private var isRunPanelVisible: Bool {
        store.step == .matrix && store.runProgress.phase != .idle
    }

    @ViewBuilder
    private var stepBody: some View {
        switch store.step {
        case .io:
            AutomationIOStepView(store: store)
        case .regions:
            AutomationRegionEditorView(store: store, backend: backend)
        case .matrix:
            if isRunPanelVisible {
                AutomationRunStatusView(
                    progress: store.runProgress,
                    onCancel: { store.cancelProcess(backend: backend) },
                    onClose: {
                        store.runProgress = AutomationRunProgress()
                        store.stepError = nil
                    }
                )
            } else {
                AutomationMatrixStepView(
                    store: store,
                    presets: backend.presets,
                    modelRatings: modelRatings,
                    menuVisibility: menuVisibility,
                    isFullscreen: isMatrixFullscreen
                )
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if store.step == .matrix, !isRunPanelVisible {
                processPresetDropdown
            }

            // Validation only (never dump run warnings here — they live on the status panel).
            if !isRunPanelVisible, let error = store.stepError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            Spacer()

            if store.step == .matrix, !isRunPanelVisible {
                if store.job.hasStep2 {
                    Button("Remove Step") {
                        store.removeMatrixStep()
                    }
                    .buttonStyle(.bordered)
                    .help("Remove pipeline step 2 (keep only first separation)")
                } else {
                    Button("Add Step") {
                        store.addMatrixStep()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(KSTheme.accent.opacity(0.85))
                    .help("Step 1 stems become Step 2 sources as Name(Stem). Max 2 steps.")
                }
            }

            Spacer()

            if isRunPanelVisible {
                if store.isProcessing {
                    Button("Cancel") {
                        store.cancelProcess(backend: backend)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button("Back to Matrix") {
                        store.runProgress = AutomationRunProgress()
                        store.stepError = nil
                    }
                    .buttonStyle(.bordered)
                    .help("Return to the stem matrix")
                    Button("Done") {
                        revealAutomationOutputsInFinder()
                        store.runProgress = AutomationRunProgress()
                        store.stepError = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(KSTheme.accent)
                    .help("Reveal created files in Finder")
                }
            } else {
                Button("Back") { store.goBack() }
                    .disabled(!store.canGoBack || store.isProcessing)
                if store.step == .matrix {
                    Button("Process") {
                        store.startProcess(backend: backend, processPresetStore: processPresetStore)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(KSTheme.accent)
                    .disabled(store.validationMessage(for: .matrix) != nil || !backend.isReady)
                    .help(backend.isReady ? "Run cut → separate → Ready MIX" : "Backend not ready")
                } else {
                    Button("Next") { store.goNext() }
                        .buttonStyle(.borderedProminent)
                        .tint(KSTheme.accent)
                        .disabled(!store.canGoNext)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// Open Finder with automation outputs selected (Ready MIX files).
    private func revealAutomationOutputsInFinder() {
        let paths = store.runProgress.producedFiles.filter {
            FileManager.default.fileExists(atPath: $0)
        }
        if !paths.isEmpty {
            // Select all created files in one Finder window.
            NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
            return
        }
        // Fallback: open Ready MIX folder even if the list was cleared/empty.
        if let folder = store.job.outputFolderPath,
           FileManager.default.fileExists(atPath: folder) {
            NSWorkspace.shared.open(URL(fileURLWithPath: folder, isDirectory: true))
        }
    }

    /// Process-settings preset (Default / Fast / Max…). Menu opens upward.
    private var processPresetDropdown: some View {
        let visiblePresets = processPresetStore.presets.filter {
            menuVisibility.isProcessPresetVisible($0.id) || $0.id == store.job.processPresetID
        }
        let title = ProcessSettingsPreset.displayTitle(
            for: store.job.processPresetID,
            in: processPresetStore.presets,
            settings: store.processSettingsAsSeparation
        )

        return Menu {
            ForEach(visiblePresets) { preset in
                Button {
                    store.applyProcessPreset(preset)
                    onProcessPresetChange?(preset.id)
                } label: {
                    if preset.id == store.job.processPresetID {
                        Label(preset.title, systemImage: "checkmark")
                    } else {
                        Text(preset.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: KSTheme.radiusSM, style: .continuous)
                    .fill(Color.secondary.opacity(0.14))
            )
            .overlay(
                RoundedRectangle(cornerRadius: KSTheme.radiusSM, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Process settings preset (opens upward)")
    }

    // MARK: - Matrix window expand / restore

    private func automationSheetWindow() -> NSWindow? {
        // Prefer the sheet hosting this view; fall back to key window.
        NSApp.windows.first(where: { $0.isVisible && $0.isSheet })
            ?? NSApp.keyWindow
    }

    private func toggleMatrixFullscreen() {
        if isMatrixFullscreen {
            collapseMatrixFullscreen(animated: true)
        } else {
            expandMatrixFullscreen()
        }
    }

    private func expandMatrixFullscreen() {
        guard let window = automationSheetWindow() else {
            isMatrixFullscreen = true
            return
        }
        // Capture BEFORE any SwiftUI layout reaction to isMatrixFullscreen.
        preExpandWindowFrame = window.frame
        preExpandMinSize = window.minSize
        preExpandMaxSize = window.maxSize

        guard let screen = window.screen ?? NSScreen.main else {
            isMatrixFullscreen = true
            return
        }
        let target = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        isMatrixFullscreen = true
        // Lock so scroll/layout cannot shrink the sheet.
        window.minSize = target.size
        window.maxSize = target.size
        window.setFrame(target, display: true, animate: true)
    }

    private func collapseMatrixFullscreen(animated: Bool) {
        guard let window = automationSheetWindow() else {
            isMatrixFullscreen = false
            preExpandWindowFrame = nil
            return
        }
        let restore = preExpandWindowFrame
            ?? NSRect(x: window.frame.midX - 500, y: window.frame.midY - 360, width: 1000, height: 720)
        let minS = preExpandMinSize ?? NSSize(width: 900, height: 600)
        let maxS = preExpandMaxSize
            ?? NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        // Unlock first so AppKit allows shrinking below the fullscreen lock.
        window.minSize = NSSize(width: 1, height: 1)
        window.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        isMatrixFullscreen = false

        let applyExact: () -> Void = {
            window.setFrame(restore, display: true, animate: false)
            // Pin to restored size briefly so SwiftUI fitting-size cannot re-grow the sheet.
            window.minSize = restore.size
            window.maxSize = restore.size
            // Next runloop: re-open min/max to original flexible limits while keeping frame.
            DispatchQueue.main.async {
                window.setFrame(restore, display: true, animate: false)
                window.minSize = minS
                window.maxSize = maxS
                // One more snap after SwiftUI has laid out with isMatrixFullscreen=false.
                DispatchQueue.main.async {
                    window.setFrame(restore, display: true, animate: false)
                }
            }
        }

        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                window.animator().setFrame(restore, display: true)
            }, completionHandler: applyExact)
        } else {
            applyExact()
        }

        preExpandWindowFrame = nil
        preExpandMinSize = nil
        preExpandMaxSize = nil
    }
}

// MARK: - Keep Matrix fullscreen locked while expanded (scroll-safe)

/// While fullscreen, re-asserts the screen-sized lock if layout tries to shrink the sheet.
/// Expand/collapse itself is driven by `toggleMatrixFullscreen()` (saves exact pre-frame).
private struct MatrixWindowSizer: NSViewRepresentable {
    var isFullscreen: Bool
    var preExpandFrame: NSRect?

    final class Coordinator {
        var lastFullscreen = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PassThroughNSView {
        PassThroughNSView(frame: .zero)
    }

    func updateNSView(_ nsView: PassThroughNSView, context: Context) {
        let was = context.coordinator.lastFullscreen
        context.coordinator.lastFullscreen = isFullscreen
        guard isFullscreen else { return }

        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            guard let screen = window.screen ?? NSScreen.main else { return }
            let target = screen.visibleFrame.insetBy(dx: 12, dy: 12)
            // Keep locked while expanded.
            if window.minSize != target.size || window.maxSize != target.size {
                window.minSize = target.size
                window.maxSize = target.size
            }
            // Only snap if something shrank us (do not animate — avoids jump while scrolling).
            if abs(window.frame.width - target.width) > 6
                || abs(window.frame.height - target.height) > 6 {
                window.setFrame(target, display: true, animate: false)
            }
            // Silence unused warning when entering first time from sizer path.
            _ = was
            _ = self.preExpandFrame
        }
    }
}

/// Zero-size helper that never participates in hit-testing (used under SwiftUI backgrounds).
private final class PassThroughNSView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Step 1: Input / Output

struct AutomationIOStepView: View {
    @ObservedObject var store: AutomationWizardStore
    @StateObject private var previewPlayer = AudioPreviewPlayer()
    /// Path currently loaded in the transport (may be paused).
    @State private var previewPath: String?
    /// Local scrub value while the user is dragging the seek slider.
    @State private var isScrubbing = false
    @State private var scrubTime: Double = 0

    private let trackRowH: CGFloat = 34
    private let trackColSpacing: CGFloat = 12
    private let trackRowSpacing: CGFloat = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Input + Output on one row (space-saving).
            HStack(alignment: .top, spacing: 16) {
                folderPicker(
                    title: "Input",
                    path: store.job.sourceFolderPath ?? "No source folder selected",
                    action: pickSource
                )
                folderPicker(
                    title: "Output (Ready MIX)",
                    path: store.job.outputFolderPath ?? "No output folder",
                    action: pickOutput
                )
            }

            if !store.job.tracks.isEmpty {
                HStack {
                    Text("Tracks (\(store.job.selectedTracks.count)/\(store.job.tracks.count))")
                        .font(.headline)
                    Spacer()
                    Button("Select all") { store.selectAllTracks(true) }
                        .controlSize(.small)
                    Button("Select none") { store.selectAllTracks(false) }
                        .controlSize(.small)
                }

                // Two equal columns; scroll only when content exceeds available height.
                GeometryReader { geo in
                    let columns = twoColumns(store.job.tracks)
                    let rowsNeeded = max(columns.left.count, columns.right.count)
                    let contentH = CGFloat(rowsNeeded) * (trackRowH + trackRowSpacing)
                    let needsScroll = contentH > geo.size.height

                    Group {
                        if needsScroll {
                            ScrollView(.vertical, showsIndicators: true) {
                                trackTwoColumn(columns)
                                    .padding(.trailing, 4)
                            }
                            .background(MatrixScrollChrome())
                        } else {
                            trackTwoColumn(columns)
                                .frame(maxHeight: .infinity, alignment: .top)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.secondary.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Full transport: play/pause + scrub + volume 0…300%.
                previewTransportBar
            } else if store.job.sourceFolderPath != nil {
                Text("No supported audio files in this folder.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "folder.badge.gearshape")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("Choose source and Ready MIX folders")
                        .font(.headline)
                    Text("Then select which tracks to process. Regions and stem matrix come next.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(16)
        .onDisappear { previewPlayer.stop() }
    }

    private var activePreviewTrack: AutomationTrackPlan? {
        guard let path = previewPath ?? previewPlayer.playingPath else { return nil }
        return store.job.tracks.first(where: { $0.sourcePath == path })
    }

    private var previewDuration: Double {
        max(previewPlayer.duration, 0.001)
    }

    private var displayedTime: Double {
        isScrubbing ? scrubTime : previewPlayer.currentTime
    }

    private var previewTransportBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    togglePreviewPlay()
                } label: {
                    Image(systemName: previewPlayer.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(KSTheme.accent.opacity(0.18)))
                        .foregroundStyle(KSTheme.accent)
                }
                .buttonStyle(.plain)
                .disabled(previewPath == nil && previewPlayer.playingPath == nil)
                .help(previewPlayer.isPlaying ? "Pause" : "Play selected track")

                Text(activePreviewTrack?.displayName ?? "Select a track to preview")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(activePreviewTrack == nil ? .secondary : .primary)
                    .frame(minWidth: 80, maxWidth: 160, alignment: .leading)

                Text(FileHelpers.formattedTimestamp(displayedTime))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)

                Slider(
                    value: Binding(
                        get: { displayedTime },
                        set: { newValue in
                            isScrubbing = true
                            scrubTime = newValue
                        }
                    ),
                    in: 0...previewDuration,
                    onEditingChanged: { editing in
                        if editing {
                            isScrubbing = true
                            scrubTime = previewPlayer.currentTime
                        } else {
                            // Commit seek on release so we don't thrash the engine while dragging.
                            let path = previewPath ?? previewPlayer.playingPath
                            if let path {
                                previewPlayer.seek(path: path, time: scrubTime)
                            }
                            isScrubbing = false
                        }
                    }
                )
                .controlSize(.small)
                .disabled(previewPath == nil && previewPlayer.playingPath == nil)
                .help("Scrub / seek — skip intro silence and audition any part of the track")

                Text(FileHelpers.formattedTimestamp(previewPlayer.duration))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .leading)

                Image(systemName: volumeIconName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Slider(
                    value: Binding(
                        get: { previewPlayer.volume },
                        set: { previewPlayer.setVolume($0) }
                    ),
                    in: 0...3
                )
                .controlSize(.small)
                .frame(maxWidth: 140)
                .help("Preview volume 0–300% (boost for quiet tracks)")
                Text("\(Int((previewPlayer.volume * 100).rounded()))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .trailing)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    private var volumeIconName: String {
        if previewPlayer.volume <= 0.001 { return "speaker.slash.fill" }
        if previewPlayer.volume < 1 { return "speaker.wave.1.fill" }
        if previewPlayer.volume < 2 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    private func togglePreviewPlay() {
        let path = previewPath ?? previewPlayer.playingPath
        guard let path else { return }
        previewPlayer.toggle(path: path)
        previewPath = path
    }

    private func selectAndTogglePreview(path: String) {
        if previewPath == path || previewPlayer.playingPath == path {
            previewPlayer.toggle(path: path)
        } else {
            // Load new track and start from beginning (user can scrub first via transport).
            previewPath = path
            isScrubbing = false
            previewPlayer.toggle(path: path)
        }
        previewPath = path
    }

    /// Load track for scrubbing without auto-play.
    private func armPreview(path: String) {
        previewPath = path
        isScrubbing = false
        if previewPlayer.playingPath != path {
            previewPlayer.prepare(path: path)
        }
    }

    // MARK: - Paths (one line)

    private func folderPicker(title: String, path: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 8) {
                pathField(path)
                Button("Choose…", action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pathField(_ text: String) -> some View {
        Text(text)
            .font(.caption.monospaced())
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(text.hasPrefix("No ") ? .secondary : .primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            .help(text)
    }

    // MARK: - Tracks 2-column grid

    private func twoColumns(_ tracks: [AutomationTrackPlan]) -> (left: [AutomationTrackPlan], right: [AutomationTrackPlan]) {
        // Fill left then right by rows: 0→L, 1→R, 2→L… so list reads top-to-bottom per column
        // with balanced heights (half / half).
        let mid = (tracks.count + 1) / 2
        let left = Array(tracks.prefix(mid))
        let right = Array(tracks.suffix(tracks.count - mid))
        return (left, right)
    }

    private func trackTwoColumn(_ columns: (left: [AutomationTrackPlan], right: [AutomationTrackPlan])) -> some View {
        HStack(alignment: .top, spacing: trackColSpacing) {
            trackColumn(columns.left)
            trackColumn(columns.right)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func trackColumn(_ tracks: [AutomationTrackPlan]) -> some View {
        VStack(spacing: trackRowSpacing) {
            ForEach(tracks) { track in
                trackRow(track)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func trackRow(_ track: AutomationTrackPlan) -> some View {
        let isArmed = previewPath == track.sourcePath || previewPlayer.playingPath == track.sourcePath
        let isPlayingThis = isArmed && previewPlayer.isPlaying

        return HStack(spacing: 6) {
            Image(systemName: track.isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(track.isSelected ? KSTheme.accent : .secondary)
                .font(.body)

            // Load + play/pause this track (transport bar can scrub it).
            Button {
                selectAndTogglePreview(path: track.sourcePath)
            } label: {
                Image(systemName: isPlayingThis ? "pause.fill" : "play.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isArmed ? KSTheme.accent : .secondary)
                    .frame(width: 22, height: 22)
                    .background(
                        Circle()
                            .fill(isArmed
                                  ? KSTheme.accent.opacity(0.18)
                                  : Color.secondary.opacity(0.12))
                    )
            }
            .buttonStyle(.plain)
            .help(isPlayingThis
                  ? "Pause · scrub below to skip intro"
                  : "Preview \(track.displayName) · use scrub bar to seek")

            Text(track.displayName)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isArmed ? .primary : .primary)
            Spacer(minLength: 0)

            if isArmed, previewPlayer.duration > 0 {
                Text(FileHelpers.formattedTimestamp(displayedTime))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: trackRowH)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    isArmed
                        ? KSTheme.accent.opacity(0.16)
                        : (track.isSelected ? KSTheme.accent.opacity(0.10) : Color.primary.opacity(0.03))
                )
        )
        .contentShape(Rectangle())
        .onTapGesture { store.toggleTrackSelection(track.id) }
        // Right-click / secondary: arm for scrub without auto-play.
        .contextMenu {
            Button("Load for scrubbing") { armPreview(path: track.sourcePath) }
            Button(isPlayingThis ? "Pause" : "Play") {
                selectAndTogglePreview(path: track.sourcePath)
            }
        }
    }

    private func pickSource() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select the folder of source recordings"
        if panel.runModal() == .OK, let url = panel.url {
            store.setSourceFolder(url)
        }
    }

    private func pickOutput() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Select Ready MIX output folder"
        if panel.runModal() == .OK, let url = panel.url {
            store.setOutputFolder(url)
        }
    }
}

// MARK: - Process status panel (full matrix area)

/// Full-size run panel: session clock + progress + compact checklist of Ready MIX files.
private struct AutomationRunStatusView: View {
    let progress: AutomationRunProgress
    var onCancel: () -> Void
    var onClose: () -> Void

    var body: some View {
        // Tick every second so session HH:MM:SS stays live while running.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let sessionSeconds = progress.sessionElapsedSeconds(now: context.date)

            VStack(spacing: 0) {
                Spacer(minLength: 8)

                VStack(spacing: 8) {
                    // Primary: total session wall time (H:MM:SS).
                    Text(Self.formatHMS(sessionSeconds))
                        .font(.system(size: 36, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(sessionClockColor)
                        .accessibilityLabel("Session time \(Self.formatHMS(sessionSeconds))")

                    // Secondary status — no giant spinner.
                    HStack(spacing: 6) {
                        if progress.phase == .completed {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else if progress.phase == .failed {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                        } else if progress.phase == .cancelled {
                            Image(systemName: "stop.circle.fill")
                                .foregroundStyle(.orange)
                        }
                        Text(progress.headline.isEmpty ? statusFallbackHeadline : progress.headline)
                            .font(.subheadline.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .lineLimit(1)
                    }

                    if !progress.currentMessage.isEmpty {
                        Text(progress.currentMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(1)
                    }

                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 480)
                        .padding(.top, 2)

                    Text("\(progress.doneCount)/\(max(progress.items.count, 1)) ready · \(progress.completedUnits)/\(max(progress.totalUnits, 1)) jobs")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 24)

                Spacer(minLength: 12)

                if !progress.items.isEmpty {
                    outputChecklist
                        .padding(.horizontal, 20)
                }

                if !progress.errors.isEmpty, progress.phase != .completed {
                    Text(progress.errors.prefix(2).joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                }

                Spacer(minLength: 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(KSTheme.panelBackground)
        }
    }

    private var sessionClockColor: Color {
        switch progress.phase {
        case .completed: return .green.opacity(0.9)
        case .failed: return .red.opacity(0.9)
        case .cancelled: return .orange.opacity(0.9)
        default: return .primary
        }
    }

    private var statusFallbackHeadline: String {
        switch progress.phase {
        case .completed: return "Automation Complete"
        case .failed: return "Automation failed"
        case .cancelled: return "Cancelled"
        case .running: return "Running automation…"
        case .idle: return ""
        }
    }

    /// `H:MM:SS` always (hours may be 0).
    static func formatHMS(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%d:%02d:%02d", h, m, s)
    }

    /// Compact per-item wall time: `11m 31s` / `45s` / `1h 02m`.
    static func formatItemElapsed(_ seconds: Double) -> String {
        FileHelpers.formattedDuration(seconds)
    }

    private var outputChecklist: some View {
        let items = progress.items
        let useTwoColumns = items.count > 4

        return Group {
            if useTwoColumns {
                let mid = (items.count + 1) / 2
                HStack(alignment: .top, spacing: 10) {
                    checklistColumn(Array(items.prefix(mid)))
                    checklistColumn(Array(items.suffix(items.count - mid)))
                }
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            } else {
                checklistColumn(items)
                    .frame(maxWidth: 340)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func checklistColumn(_ items: [AutomationProgressItem]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(items) { item in
                HStack(spacing: 6) {
                    itemIcon(item.status)
                        .frame(width: 14, height: 14)
                    Text(item.title)
                        .font(.caption.weight(item.status == .done ? .medium : .regular))
                        .foregroundStyle(item.status == .pending ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if let elapsed = item.elapsedSeconds, item.status == .done || item.status == .failed {
                        Text(Self.formatItemElapsed(elapsed))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if item.status == .step1Done, let s1 = item.step1ElapsedSeconds {
                        Text("S1 \(Self.formatItemElapsed(s1))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    } else if item.status == .running, let started = item.startedAt {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text(Self.formatItemElapsed(ctx.date.timeIntervalSince(started)))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(KSTheme.accent)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(item.status == .done
                              ? Color.green.opacity(0.10)
                              : item.status == .step1Done
                              ? Color.orange.opacity(0.10)
                              : Color.secondary.opacity(0.07))
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func itemIcon(_ status: AutomationProgressItemStatus) -> some View {
        switch status {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.green)
        case .step1Done:
            Image(systemName: "clock.badge.checkmark")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
        case .running:
            ProgressView()
                .controlSize(.mini)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.red)
        case .pending:
            Image(systemName: "circle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary.opacity(0.5))
        }
    }
}

// MARK: - Matrix

struct AutomationMatrixStepView: View {
    @ObservedObject var store: AutomationWizardStore
    /// Snapshot of model list — do **not** observe BackendClient here.
    /// Telemetry refreshes `runtimeStats` every 2s and would re-render every stem cell.
    var presets: [SeparationPreset]
    var modelRatings: [String: Int] = [:]
    @ObservedObject var menuVisibility: MenuVisibilityStore = .shared
    var isFullscreen: Bool = false

    /// Source / Final rail (includes horizontal padding).
    private let sourceColW: CGFloat = 148
    private let finalColW: CGFloat = 140
    /// ~25% narrower than previous 168 — fits 2×3 icons without huge gaps.
    private let modelW: CGFloat = 126
    private let rowH: CGFloat = 96
    private let headerH: CGFloat = 44
    private let iconSize: CGFloat = 28
    private let iconHitSize: CGFloat = 36
    private let gridColSpacing: CGFloat = 8
    private let gridRowSpacing: CGFloat = 10
    private let railGray = Color.secondary.opacity(0.12)

    private var showingStep2: Bool {
        store.job.hasStep2 && store.job.matrixPipelineStep == 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("Stem matrix")
                    .font(.headline)
                if store.job.hasStep2 {
                    pipelineStepPicker
                }
                Text(showingStep2
                     ? "Step 2 sources = Step 1 finals as Name(Stem)"
                     : "scroll · ⌘+scroll horizontal · Add Step for 2nd pass")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if store.job.hasStep2 {
                    Toggle(isOn: Binding(
                        get: { store.job.saveStep1Outputs },
                        set: { store.setSaveStep1Outputs($0) }
                    )) {
                        Text("Save Step 1")
                            .font(.caption.weight(.medium))
                    }
                    .toggleStyle(.checkbox)
                    .help(
                        "Keep Step 1 stems permanently under Ready MIX/Step 1/ "
                            + "and write Step 2 finals to Ready MIX/Step 2/. "
                            + "Off = only finals (Step 1 intermediates deleted)."
                    )
                }
                Spacer()
                Text(statusSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if store.job.selectedTracks.isEmpty {
                Text("No tracks selected.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else if models.isEmpty {
                VStack(spacing: 8) {
                    Text("No models visible")
                        .font(.headline)
                    Text("Open the eye on models in Settings so they appear here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if showingStep2 && store.job.step2Tracks.isEmpty {
                Text("Step 2 is empty — press Add Step again after selecting stems in Step 1.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                matrixTable
            }
        }
        .padding(isFullscreen ? 16 : 12)
    }

    private var statusSummary: String {
        let keep = store.job.hasStep2 && store.job.saveStep1Outputs ? " · keep Step 1" : ""
        if showingStep2 {
            return "Step 2 · \(store.job.selectedStep2Tracks.count) intermediates · \(store.job.estimatedWorkUnitCount()) jobs\(keep)"
        }
        let s2 = store.job.hasStep2 ? " · +Step 2" : ""
        return "Step 1 · \(store.job.selectedTracks.count) tracks · \(store.job.estimatedWorkUnitCount()) jobs\(s2)\(keep)"
    }

    private var pipelineStepPicker: some View {
        Picker("", selection: Binding(
            get: { store.job.matrixPipelineStep },
            set: { store.setMatrixPipelineStep($0) }
        )) {
            Text("Step 1").tag(1)
            Text("Step 2").tag(2)
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 180)
        .labelsHidden()
        .help("Step 1: originals → stems. Step 2: those stems → final Ready MIX.")
    }

    private var matrixTable: some View {
        ScrollView([.horizontal, .vertical], showsIndicators: true) {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    if showingStep2 {
                        ForEach(store.job.step2Tracks) { track in
                            step2DataRow(track)
                            rowDivider.frame(width: tableWidth)
                        }
                    } else {
                        ForEach(store.job.selectedTracks) { track in
                            step1DataRow(track)
                            rowDivider.frame(width: tableWidth)
                        }
                    }
                } header: {
                    headerRow
                        .background(KSTheme.panelBackground)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(Color.white.opacity(0.12))
                                .frame(height: 1)
                        }
                }
            }
            .frame(width: tableWidth, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MatrixScrollChrome())
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear {
            store.configureMatrixPresets(presets)
        }
        .onChange(of: presets) { updatedPresets in
            store.configureMatrixPresets(updatedPresets)
        }
    }

    /// Only models the user left visible (eye open) in Settings / header menu.
    private var models: [SeparationPreset] {
        presets.filter { menuVisibility.isModelVisible($0.id) }
    }

    /// Full table width so horizontal scroll has real overflow to pan.
    private var tableWidth: CGFloat {
        let n = CGFloat(models.count)
        let dividers = max(0, n - 1) // 1pt col separators
        return sourceColW + n * modelW + dividers + finalColW
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            Text(showingStep2 ? "From Step 1" : "Source")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: sourceColW - 20, height: headerH, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(width: sourceColW, height: headerH, alignment: .leading)
                .background(railGray)

            ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                if index > 0 { colDivider(height: headerH - 12) }
                modelHeaderCell(model)
            }

            Text(showingStep2 ? "Final name" : "Final name")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: finalColW - 16, height: headerH, alignment: .leading)
                .padding(.horizontal, 8)
                .frame(width: finalColW, height: headerH, alignment: .leading)
                .background(railGray)
        }
        .frame(width: tableWidth, height: headerH, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
    }

    private func step1DataRow(_ track: AutomationTrackPlan) -> some View {
        HStack(spacing: 0) {
            Text(track.displayName)
                .font(.caption.weight(.medium))
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(width: sourceColW - 20, height: rowH, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(width: sourceColW, height: rowH, alignment: .leading)
                .background(railGray)
                .help(track.displayName)

            ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                if index > 0 { colDivider(height: rowH - 16) }
                stemGridStep1(track: track, model: model)
                    .frame(width: modelW, height: rowH)
            }

            TextField(
                "Main Vocal",
                text: Binding(
                    get: {
                        store.job.tracks.first(where: { $0.id == track.id })?.shortOutputName
                            ?? track.shortOutputName
                    },
                    set: { store.setShortName(for: track.id, name: $0) }
                )
            )
            .textFieldStyle(.roundedBorder)
            .font(.caption)
            .frame(width: finalColW - 16)
            .padding(.horizontal, 8)
            .frame(width: finalColW, height: rowH)
            .background(railGray)
            .accessibilityIdentifier("automation-matrix-step1-final-name-\(track.id.uuidString)")
        }
        .frame(width: tableWidth, height: rowH, alignment: .leading)
        .background(Color.primary.opacity(0.02))
    }

    private func step2DataRow(_ track: AutomationStep2TrackPlan) -> some View {
        HStack(spacing: 0) {
            // Intermediate source: MAIN_V(Vocal) — click toggles inclusion
            HStack(spacing: 4) {
                Image(systemName: track.isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.caption)
                    .foregroundStyle(track.isSelected ? KSTheme.accent : .secondary)
                Text(track.displayName)
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            .frame(width: sourceColW - 20, height: rowH, alignment: .leading)
            .padding(.horizontal, 10)
            .frame(width: sourceColW, height: rowH, alignment: .leading)
            .background(railGray)
            .contentShape(Rectangle())
            .onTapGesture { store.toggleStep2TrackSelection(track.id) }
            .help("\(track.displayName) · from \(track.fromStem) of step 1")
            .opacity(track.isSelected ? 1 : 0.45)

            ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                if index > 0 { colDivider(height: rowH - 16) }
                stemGridStep2(track: track, model: model)
                    .frame(width: modelW, height: rowH)
                    .opacity(track.isSelected ? 1 : 0.35)
            }

            TextField(
                "Final",
                text: Binding(
                    get: {
                        store.job.step2Tracks.first(where: { $0.id == track.id })?.shortOutputName
                            ?? track.shortOutputName
                    },
                    set: { store.setStep2ShortName(for: track.id, name: $0) }
                )
            )
            .textFieldStyle(.roundedBorder)
            .font(.caption)
            .frame(width: finalColW - 16)
            .padding(.horizontal, 8)
            .frame(width: finalColW, height: rowH)
            .background(railGray)
            .accessibilityIdentifier("automation-matrix-step2-final-name-\(track.id.uuidString)")
            .disabled(!track.isSelected)
            .opacity(track.isSelected ? 1 : 0.45)
        }
        .frame(width: tableWidth, height: rowH, alignment: .leading)
        .background(Color.primary.opacity(0.02))
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 1)
    }

    private func colDivider(height: CGFloat) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: 1, height: height)
    }

    /// Model title + user star rating (same 0…3 scale as the main model menu).
    private func modelHeaderCell(_ model: SeparationPreset) -> some View {
        let rating = min(3, max(0, modelRatings[model.id] ?? 0))
        return VStack(spacing: 2) {
            Text(model.title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: .infinity)

            HStack(spacing: 1) {
                ForEach(1...3, id: \.self) { star in
                    Image(systemName: star <= rating ? "star.fill" : "star")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(star <= rating ? Color.orange : Color.secondary.opacity(0.28))
                }
            }
            .accessibilityLabel(rating > 0 ? "\(rating) of 3 stars" : "No rating")
        }
        .frame(width: modelW, height: headerH)
        .help(rating > 0 ? "\(model.title) · \(rating)/3 stars" : "\(model.title) · unrated")
    }

    /// Fixed 3×2 slots so icons line up across every model column.
    private func stemGridStep1(track: AutomationTrackPlan, model: SeparationPreset) -> some View {
        let identity = "step1-\(track.id.uuidString)-\(model.id)"
        return stemIconGrid(stems: model.expectedStems, identity: identity) { stem in
            StemRoleIconButton(
                stem: stem,
                size: iconSize,
                isOn: store.isStemSelected(trackID: track.id, modelID: model.id, stem: stem),
                action: {
                    guard model.expectedStems.contains(stem) else { return }
                    store.toggleStem(trackID: track.id, modelID: model.id, stem: stem)
                }
            )
            .accessibilityIdentifier("\(identity)-\(stem)")
        }
    }

    private func stemGridStep2(track: AutomationStep2TrackPlan, model: SeparationPreset) -> some View {
        let identity = "step2-\(track.id.uuidString)-\(model.id)"
        return stemIconGrid(stems: model.expectedStems, identity: identity) { stem in
            StemRoleIconButton(
                stem: stem,
                size: iconSize,
                isOn: store.isStep2StemSelected(trackID: track.id, modelID: model.id, stem: stem),
                action: {
                    guard track.isSelected, model.expectedStems.contains(stem) else { return }
                    store.toggleStep2Stem(trackID: track.id, modelID: model.id, stem: stem)
                }
            )
            .accessibilityIdentifier("\(identity)-\(stem)")
        }
    }

    private func stemIconGrid<Content: View>(
        stems: [String],
        identity: String,
        @ViewBuilder cell: @escaping (String) -> Content
    ) -> some View {
        VStack(spacing: gridRowSpacing) {
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: gridColSpacing) {
                    ForEach(0..<3, id: \.self) { col in
                        let idx = row * 3 + col
                        if idx < stems.count {
                            let stem = stems[idx]
                            cell(stem)
                                // Give each icon its own padded, rectangular target.
                                // The role is part of identity so a reordered catalog
                                // cannot reuse a neighboring role's view state.
                                .frame(width: iconHitSize, height: iconHitSize)
                                .contentShape(Rectangle())
                                .id("\(identity)-stem-\(stem)")
                        } else {
                            Color.clear
                                .frame(width: iconHitSize, height: iconHitSize)
                                .id("\(identity)-empty-\(idx)")
                        }
                    }
                }
                .id("\(identity)-row-\(row)")
            }
        }
        .frame(width: modelW, height: rowH)
        .id(identity)
    }
}

// MARK: - Matrix scroll chrome (⌘+scroll + softer system scrollers)

/// Background host: ⌘/⌃+wheel → horizontal pan; dims system scrollers without replacing them
/// (replacing NSScrollers broke dual-axis trackpad scrolling).
///
/// Important: do **not** re-apply scroller chrome on every SwiftUI `updateNSView` /
/// `layout` — that fed an infinite main-thread update loop (100% CPU, multi‑GB RAM)
/// when the matrix hosted hundreds of `NSViewRepresentable` stem icons.
private struct MatrixScrollChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> MatrixScrollChromeNSView {
        MatrixScrollChromeNSView()
    }

    func updateNSView(_ nsView: MatrixScrollChromeNSView, context: Context) {
        // Intentionally no-op: chrome is applied once when the view joins a window.
    }
}

private final class MatrixScrollChromeNSView: NSView {
    private var monitor: Any?
    private var didApplyChrome = false

    /// Never steal clicks from stem icons / rows / text fields above this chrome.
    /// This was the recurring “matrix icons do nothing” bug: the background NSView
    /// sat on top of the hit-test chain and ate every mouseDown.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        guard window != nil else {
            didApplyChrome = false
            return
        }
        installCommandScrollMonitor()
        // One deferred pass after SwiftUI installs the real NSScrollView.
        DispatchQueue.main.async { [weak self] in
            self?.applyScrollerChromeIfNeeded()
        }
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func applyScrollerChromeIfNeeded() {
        guard !didApplyChrome else { return }
        applyScrollerChrome()
        // Mark applied only if we found a scroll view; otherwise retry once later.
        if enclosingScrollView != nil || findScrollView(from: superview) != nil {
            didApplyChrome = true
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, !self.didApplyChrome else { return }
                self.applyScrollerChrome()
                self.didApplyChrome = true
            }
        }
    }

    private func installCommandScrollMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let window = self.window, window.isKeyWindow else { return event }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard mods.contains(.command) || mods.contains(.control) else { return event }

            let loc = window.mouseLocationOutsideOfEventStream
            let area = self.superview?.bounds ?? self.bounds
            let testPoint = self.superview?.convert(loc, from: nil)
                ?? self.convert(loc, from: nil)
            guard area.contains(testPoint) else { return event }

            guard let scrollView = self.enclosingScrollView
                    ?? self.findScrollView(from: self.superview) else {
                return event
            }

            let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
            let clip = scrollView.contentView
            var origin = clip.bounds.origin
            origin.x = max(0, origin.x + delta * 2.5)
            if let doc = scrollView.documentView {
                let maxX = max(0, doc.bounds.width - clip.bounds.width)
                origin.x = min(origin.x, maxX)
            }
            clip.scroll(to: origin)
            scrollView.reflectScrolledClipView(clip)
            return nil
        }
    }

    private func applyScrollerChrome() {
        guard let scrollView = enclosingScrollView ?? findScrollView(from: superview) else { return }

        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.scrollerKnobStyle = .light
        // Soften only — do not replace scroller instances (breaks SwiftUI dual-axis scroll).
        scrollView.verticalScroller?.controlSize = .mini
        scrollView.horizontalScroller?.controlSize = .mini
        scrollView.verticalScroller?.alphaValue = 0.45
        scrollView.horizontalScroller?.alphaValue = 0.45
    }

    private func findScrollView(from view: NSView?) -> NSScrollView? {
        var v = view
        while let cur = v {
            if let s = cur as? NSScrollView { return s }
            for child in cur.subviews {
                if let s = child as? NSScrollView { return s }
                if let s = findScrollViewDeep(child, depth: 5) { return s }
            }
            v = cur.superview
        }
        return nil
    }

    private func findScrollViewDeep(_ view: NSView, depth: Int) -> NSScrollView? {
        if depth <= 0 { return nil }
        if let s = view as? NSScrollView { return s }
        for child in view.subviews {
            if let s = findScrollViewDeep(child, depth: depth - 1) { return s }
        }
        return nil
    }
}

/// Matrix stem icon — pure SwiftUI so clicks work inside dual-axis ScrollView.
/// (NSViewRepresentable icons were regularly blocked by background chrome hit-testing.)
private struct StemRoleIconButton: View {
    let stem: String
    var size: CGFloat = 30
    let isOn: Bool
    let action: () -> Void

    private var instrumentName: String {
        StemRoleStyle.accessibilityLabel(for: stem)
    }

    private var roleColor: Color {
        StemRoleStyle.color(for: stem)
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isOn ? roleColor : roleColor.opacity(0.14))
                Circle()
                    .strokeBorder(roleColor.opacity(isOn ? 0 : 0.4), lineWidth: 1)
                Image(systemName: StemRoleStyle.systemImage(for: stem))
                    .font(.system(size: max(9, size * 0.42), weight: .semibold))
                    .foregroundStyle(isOn ? Color.white : roleColor)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            // The label fills the outer hit target so padded clicks still
            // invoke this role's Button rather than a neighboring cell.
            .frame(width: size + 8, height: size + 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(instrumentName)
        .accessibilityLabel(instrumentName)
        .accessibilityValue(isOn ? "keep" : "skip")
        .accessibilityHint("Toggle whether this stem is kept in Ready MIX")
    }
}
