import Foundation
import Network

enum BackendClientError: Error, LocalizedError {
    case notRunning
    case launchFailed(String)
    case invalidResponse(String)
    case backend(String)
    case timeout
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notRunning:
            return "Backend is not running."
        case .launchFailed(let message):
            return message
        case .invalidResponse(let message):
            return "Invalid backend response: \(message)"
        case .backend(let message):
            return message
        case .timeout:
            return "Backend startup timed out."
        case .cancelled:
            return "Operation cancelled."
        }
    }
}

@MainActor
final class BackendClient: ObservableObject {
    @Published var isReady = false
    @Published var isProcessing = false
    @Published var isCancelling = false
    @Published var progress: Double = 0
    @Published var currentStage = "Backend stopped"
    @Published var statusLine = "Not started"
    @Published var errorMessage: String?
    @Published var backendLog = ""
    @Published var presets: [SeparationPreset] = []
    @Published var models: [SeparatorModel] = []
    @Published var runtimeStats: RuntimeSnapshot?
    @Published var modelCache: ModelCache?
    @Published var lastSummary: SeparationSummary?
    @Published var renderEstimate: RenderEstimate?
    @Published var backendLogPath: String?
    @Published var previewProgress: AudioPreviewProgress?

    private var process: Process?
    private var connection: NWConnection?
    private var inputPipe: Pipe?
    private var outputBuffer = ""
    private var pendingRequests: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var requestCounter = 0
    private var telemetryTask: Task<Void, Never>?
    private var isTelemetryRequestInFlight = false
    private var backendPaths: BackendPaths?
    private let networkQueue = DispatchQueue(label: "AuraSplitter.BackendConnection")
    private var analysisProgressSinks: [String: ([String: Any]) -> Void] = [:]
    /// Serializes start / cancel-restart / manual restart so they cannot thrash the TCP port.
    private var isPerformingBackendLifecycle = false
    /// Set when the active NWConnection fails; aborts waitUntilReady early.
    private var connectionFailure: Error?

    var isBusy: Bool {
        isProcessing || isCancelling || isPerformingBackendLifecycle
    }

    var modelSetupMessage: String? {
        guard isProcessing else { return nil }
        if currentStage.contains("Downloading and converting model for MLX") ||
            currentStage.contains("Converting model for MLX") {
            return currentStage
        }
        return nil
    }

    func start() async throws {
        if isReady { return }

        let paths = resolveBackendPaths()
        backendPaths = paths
        if let tcpPort = paths.tcpPort {
            try await ensureTCPBackendRunning(paths: paths, port: tcpPort, forceRelaunch: false)
            return
        }

        guard FileManager.default.fileExists(atPath: paths.python) else {
            throw BackendClientError.launchFailed("Python not found at \(paths.python). Run script/setup_backend.sh first.")
        }
        guard FileManager.default.fileExists(atPath: paths.server) else {
            throw BackendClientError.launchFailed("Backend server not found at \(paths.server).")
        }
        guard FileManager.default.fileExists(atPath: paths.backendLauncher) else {
            throw BackendClientError.launchFailed("Backend launcher not found at \(paths.backendLauncher).")
        }

        currentStage = "Starting backend"
        statusLine = "Launching Python backend"
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: paths.runtimeDir),
            withIntermediateDirectories: true
        )

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [paths.backendLauncher]
        proc.currentDirectoryURL = URL(fileURLWithPath: paths.runtimeDir)

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONPATH"] = paths.pythonPath
        environment["KIRTAN_SPLITTER_PROJECT_ROOT"] = paths.projectRoot
        environment["KIRTAN_SPLITTER_PYTHON"] = paths.python
        environment["KIRTAN_SPLITTER_BACKEND_SERVER"] = paths.server
        environment["KIRTAN_SPLITTER_MODEL_DIR"] = paths.modelDir
        environment["KIRTAN_SPLITTER_LOG_FILE"] = paths.logFile
        environment["MLX_USE_FAST_SDP"] = "1"
        proc.environment = environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                self?.handleStdout(text)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                self?.appendLog(text)
            }
        }

        self.process = proc
        self.inputPipe = stdinPipe

        do {
            try proc.run()
        } catch {
            throw BackendClientError.launchFailed(error.localizedDescription)
        }

        do {
            try await waitUntilReady(timeoutSeconds: 30)
        } catch {
            proc.terminate()
            self.process = nil
            self.inputPipe = nil
            throw error
        }
        statusLine = "Backend ready"
        startTelemetryLoop()
    }

    /// Connect-only: assumes a backend is already listening on the port.
    private func connectTCPBackend(paths: BackendPaths, port: Int, timeoutSeconds: Double) async throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw BackendClientError.launchFailed("Invalid backend TCP port: \(port)")
        }

        connection?.cancel()
        connection = nil
        isReady = false
        connectionFailure = nil
        outputBuffer = ""
        currentStage = "Connecting backend"
        statusLine = "Connecting to local backend"

        let conn = NWConnection(host: NWEndpoint.Host(paths.tcpHost ?? "127.0.0.1"), port: endpointPort, using: .tcp)
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            // Only .failed aborts waitUntilReady. .waiting is normal while the peer binds.
            if case .failed(let error) = state {
                Task { @MainActor [weak self] in
                    self?.connectionFailure = error
                    self?.appendLog("Backend connection failed: \(error.localizedDescription)\n")
                }
            }
        }
        conn.start(queue: networkQueue)
        receiveFromConnection(conn)

        do {
            try await waitUntilReady(timeoutSeconds: timeoutSeconds)
        } catch {
            conn.cancel()
            if connection === conn {
                connection = nil
            }
            throw error
        }
        statusLine = "Backend ready"
        startTelemetryLoop()
    }

    /// Single-flight start/restart for the detached TCP worker.
    private func ensureTCPBackendRunning(paths: BackendPaths, port: Int, forceRelaunch: Bool) async throws {
        // Join any in-flight lifecycle instead of stacking kills/launches (restart storms).
        if isPerformingBackendLifecycle {
            let waitStarted = Date()
            while isPerformingBackendLifecycle {
                if Date().timeIntervalSince(waitStarted) > 60 {
                    throw BackendClientError.timeout
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            // Peer already finished — reuse success; only continue if still down.
            if isReady { return }
        } else if isReady, !forceRelaunch {
            return
        }

        isPerformingBackendLifecycle = true
        defer { isPerformingBackendLifecycle = false }

        let host = paths.tcpHost ?? "127.0.0.1"
        telemetryTask?.cancel()
        telemetryTask = nil

        let needsLaunch = forceRelaunch || !isTCPPortOpen(host: host, port: port)
        if needsLaunch {
            currentStage = forceRelaunch ? "Restarting backend" : "Starting backend"
            statusLine = forceRelaunch ? "Stopping previous backend worker" : "Launching backend worker"
            isReady = false
            connection?.cancel()
            connection = nil

            // Hard stop: soft cancel exit can leave a Metal/MLX worker holding the port.
            terminateRuntimeBackendProcesses(paths: paths, port: port)
            try await waitForTCPPortToClose(host: host, port: port, timeoutSeconds: 6.0, throwOnTimeout: false)
            if isTCPPortOpen(host: host, port: port) {
                terminateRuntimeBackendProcesses(paths: paths, port: port, forceKill: true)
                try await waitForTCPPortToClose(host: host, port: port, timeoutSeconds: 8.0, throwOnTimeout: true)
            }

            statusLine = "Launching backend worker"
            try launchDetachedTCPBackend(paths: paths, port: port)
            try await waitForTCPPortToOpen(host: host, port: port, timeoutSeconds: 20.0)
        }

        // Connect with retries — first connection after kill can race TIME_WAIT / late bind.
        var lastError: Error = BackendClientError.timeout
        for attempt in 1...4 {
            do {
                try await connectTCPBackend(paths: paths, port: port, timeoutSeconds: attempt == 1 ? 15 : 20)
                errorMessage = nil
                return
            } catch {
                lastError = error
                appendLog("Backend connect attempt \(attempt) failed: \(error.localizedDescription)\n")
                connection?.cancel()
                connection = nil
                isReady = false

                if !isTCPPortOpen(host: host, port: port) {
                    statusLine = "Relaunching backend worker"
                    terminateRuntimeBackendProcesses(paths: paths, port: port, forceKill: true)
                    try await waitForTCPPortToClose(host: host, port: port, timeoutSeconds: 4.0, throwOnTimeout: false)
                    try launchDetachedTCPBackend(paths: paths, port: port)
                    try await waitForTCPPortToOpen(host: host, port: port, timeoutSeconds: 20.0)
                } else {
                    try await Task.sleep(nanoseconds: 400_000_000)
                }
            }
        }
        throw lastError
    }

    func stop() {
        process?.terminate()
        connection?.cancel()
        process = nil
        connection = nil
        inputPipe = nil
        cancelPendingRequests(throwing: BackendClientError.cancelled)
        isReady = false
        isProcessing = false
        isCancelling = false
        statusLine = "Backend stopped"
        currentStage = "Backend stopped"
        telemetryTask?.cancel()
        telemetryTask = nil
    }

    func loadInitialData() async {
        do {
            presets = try await listPresets()
            models = try await listModels(limit: 500)
            runtimeStats = try await fetchRuntimeStats()
            modelCache = try await fetchModelCache()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func listPresets() async throws -> [SeparationPreset] {
        let result = try await sendRequest(method: "list_presets", params: [:])
        return try decodeArray(SeparationPreset.self, from: result, key: "presets")
    }

    func listModels(limit: Int) async throws -> [SeparatorModel] {
        let result = try await sendRequest(method: "list_models", params: ["limit": limit])
        return try decodeArray(SeparatorModel.self, from: result, key: "models")
    }

    func fetchRuntimeStats() async throws -> RuntimeSnapshot {
        let result = try await sendRequest(method: "runtime_stats", params: [:])
        return try decodeObject(RuntimeSnapshot.self, from: result)
    }

    func fetchModelCache() async throws -> ModelCache {
        let result = try await sendRequest(method: "model_cache", params: [:])
        return try decodeObject(ModelCache.self, from: result)
    }

    func analyzeAudio(url: URL) async throws -> AudioAnalysis {
        if LocalAudioAnalyzer.canAnalyzeLocally(url) {
            do {
                let analysis = try await Task.detached(priority: .userInitiated) {
                    try LocalAudioAnalyzer.analyze(url: url)
                }.value
                previewProgress = AudioPreviewProgress(completedWith: analysis)
                return analysis
            } catch {
                // Fall through to the backend progressive path.
            }
        }

        let requestID = nextRequestID()
        let params: [String: Any] = [
            "path": url.path,
            "waveformPoints": AudioPreviewAnalysisResolution.waveformPoints,
            "spectrogramColumns": AudioPreviewAnalysisResolution.spectrogramColumns,
            "spectrogramBins": AudioPreviewAnalysisResolution.spectrogramBins,
            "binaryPayload": true,
            "progressive": true,
        ]

        let progress = AudioPreviewProgress(path: url.path)
        previewProgress = progress
        analysisProgressSinks[requestID] = { [weak self] message in
            self?.applyAnalysisProgress(message)
        }
        defer {
            analysisProgressSinks.removeValue(forKey: requestID)
            previewProgress?.phase = .complete
            previewProgress?.isSpectrogramLoading = false
        }

        let result = try await sendRequest(method: "analyze_audio", params: params, requestID: requestID)
        var analysis = try decodeObject(AudioAnalysis.self, from: result)
        if let payloadPath = analysis.binaryPayloadPath {
            let payload = try AudioAnalysis.readKsbin(at: URL(fileURLWithPath: payloadPath))
            analysis.waveformPeaks = payload.waveformPeaks
            analysis.spectrogram = payload.spectrogram
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: payloadPath))
        }
        previewProgress = AudioPreviewProgress(completedWith: analysis)
        return analysis
    }

    private func applyAnalysisProgress(_ message: [String: Any]) {
        guard var progress = previewProgress else { return }
        let payload = message["result"] as? [String: Any] ?? [:]
        let phase = payload["phase"] as? String ?? ""
        switch phase {
        case "waveform_preview":
            progress.phase = .waveformPreview
            if let waveform = payload["waveformPeaks"] as? [Double] {
                progress.previewWaveform = waveform
            }
            progress.durationSeconds = payload["durationSeconds"] as? Double ?? progress.durationSeconds
            progress.channels = payload["channels"] as? Int ?? progress.channels
            progress.sampleRate = payload["sampleRate"] as? Int ?? progress.sampleRate
            progress.peakDb = payload["peakDb"] as? Double ?? progress.peakDb
            progress.clipped = payload["clipped"] as? Bool ?? progress.clipped
        case "waveform_full":
            progress.phase = .waveformFull
            if let path = payload["binaryPayloadPath"] as? String,
               let payload = try? AudioAnalysis.readKsbin(at: URL(fileURLWithPath: path)) {
                progress.fullWaveform = payload.waveformPeaks
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: path))
            }
        case "spectrogram_chunk":
            progress.phase = .spectrogramChunking
            if let path = payload["binaryPayloadPath"] as? String,
               let chunk = try? AudioAnalysis.readKsbin(at: URL(fileURLWithPath: path)) {
                let spec = chunk.spectrogram
                let start = payload["columnsStart"] as? Int ?? 0
                let totalColumns = payload["totalColumns"] as? Int ?? spec.columns
                let totalBins = payload["bins"] as? Int ?? spec.bins
                progress.applySpectrogramChunk(spec, columnsStart: start, totalColumns: totalColumns, totalBins: totalBins)
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: path))
            }
        default:
            break
        }
        previewProgress = progress
    }

    func deleteModelCacheItem(_ item: ModelCacheItem) async {
        guard !isProcessing else { return }
        do {
            let result = try await sendRequest(method: "delete_model_cache_item", params: ["path": item.path])
            modelCache = try decodeObject(ModelCache.self, from: result)
            runtimeStats = try? await fetchRuntimeStats()
            statusLine = "Deleted \(item.filename)"
        } catch {
            errorMessage = error.localizedDescription
            appendLog("Model cache delete failed: \(error.localizedDescription)\n")
        }
    }

    func deleteModelGroupSource(_ group: ModelCacheGroup) async {
        guard !isProcessing else { return }
        do {
            let result = try await sendRequest(method: "delete_model_group_source", params: ["groupID": group.id])
            modelCache = try decodeObject(ModelCache.self, from: result)
            runtimeStats = try? await fetchRuntimeStats()
            statusLine = "Deleted source for \(group.displayName)"
        } catch {
            errorMessage = error.localizedDescription
            appendLog("Model source delete failed: \(error.localizedDescription)\n")
        }
    }

    func clearBackendLog() {
        backendLog = ""
        guard let backendLogPath else { return }
        try? "".write(toFile: backendLogPath, atomically: true, encoding: .utf8)
    }

    @discardableResult
    func fetchRenderEstimate(
        inputURL: URL,
        durationSeconds: Double?,
        settings: SeparationSettings,
        processPreset: ProcessSettingsPreset?
    ) async throws -> RenderEstimate {
        let isDirty = processPreset?.isDirty(settings: settings) ?? true
        let presetTitle = isDirty ? "Custom" : (processPreset?.title ?? "Default")
        let presetID = isDirty ? "custom" : (processPreset?.id ?? "builtin.default")

        var params: [String: Any] = [
            "inputPath": inputURL.path,
            "preset": settings.presetID,
            "processPresetID": presetID,
            "processPresetTitle": presetTitle,
            "mdxcSegmentSize": settings.mdxcSegmentSize,
            "mdxcOverlap": settings.mdxcOverlap,
            "mdxcBatchSize": settings.mdxcBatchSize,
            "chunkDuration": settings.chunkDuration,
            "speedMode": settings.speedMode,
            "performanceFlags": settings.performanceFlags,
        ]
        if let modelOverride = settings.modelOverride, !modelOverride.isEmpty {
            params["modelFilename"] = modelOverride
        }
        if let durationSeconds, durationSeconds > 0 {
            params["durationSeconds"] = durationSeconds
        }
        if let gpuCoreCount = runtimeStats?.gpu.gpuCoreCount {
            params["gpuCoreCount"] = gpuCoreCount
        }

        let result = try await sendRequest(method: "render_estimate", params: params)
        let estimate = try decodeObject(RenderEstimate.self, from: result)
        renderEstimate = estimate
        return estimate
    }

    func separate(
        inputURL: URL,
        outputDirectory: URL,
        settings: SeparationSettings,
        processPreset: ProcessSettingsPreset?
    ) async throws -> SeparationSummary {
        guard !isCancelling else {
            throw BackendClientError.cancelled
        }

        isProcessing = true
        isCancelling = false
        progress = 0
        currentStage = "Preparing"
        statusLine = "Starting separation"
        defer {
            isProcessing = false
        }

        let isDirty = processPreset?.isDirty(settings: settings) ?? true
        let presetTitle = isDirty ? "Custom" : (processPreset?.title ?? "Default")
        let presetID = isDirty ? "custom" : (processPreset?.id ?? "builtin.default")

        var params: [String: Any] = [
            "inputPath": inputURL.path,
            "outputDir": outputDirectory.path,
            "preset": settings.presetID,
            "outputFormat": settings.outputFormat,
            "speedMode": settings.speedMode,
            "mdxcSegmentSize": settings.mdxcSegmentSize,
            "mdxcOverlap": settings.mdxcOverlap,
            "mdxcBatchSize": settings.mdxcBatchSize,
            "mdxcOverrideModelSegmentSize": settings.effectiveMDXCOverrideModelSegmentSize,
            "saveConvertedSafetensors": settings.saveConvertedSafetensors,
            "performanceFlags": settings.performanceFlags,
            "processPresetID": presetID,
            "processPresetTitle": presetTitle,
        ]
        if let modelOverride = settings.modelOverride, !modelOverride.isEmpty {
            params["modelFilename"] = modelOverride
        }
        if let chunkDuration = settings.chunkDurationForBackend {
            params["chunkDuration"] = chunkDuration
        }

        let requestID = nextRequestID()
        let result: [String: Any]
        do {
            result = try await sendRequest(method: "separate", params: params, requestID: requestID)
        } catch BackendClientError.cancelled {
            currentStage = "Cancelled"
            statusLine = "Cancelled by user"
            throw BackendClientError.cancelled
        }
        let summary = try decodeObject(SeparationSummary.self, from: result)
        progress = 1
        currentStage = "Complete"
        let report = LastRunReport(summary: summary)
        statusLine = "Done · \(report.statusLineSummary)"
        lastSummary = summary
        if let cache = summary.modelCache {
            modelCache = cache
        } else {
            modelCache = try? await fetchModelCache()
        }
        presets = (try? await listPresets()) ?? presets
        _ = try? await fetchRenderEstimate(
            inputURL: inputURL,
            durationSeconds: nil,
            settings: settings,
            processPreset: processPreset
        )
        return summary
    }

    func cancelCurrentOperation() async {
        guard !isCancelling else { return }
        guard isProcessing || !pendingRequests.isEmpty else { return }

        let paths = backendPaths ?? resolveBackendPaths()
        backendPaths = paths
        isCancelling = true
        errorMessage = nil
        currentStage = "Cancelling"
        statusLine = "Cancelling current operation"

        // Best-effort cooperative cancel so the worker can drop caches before we kill it.
        if paths.tcpPort != nil {
            do {
                try await sendOutOfBandCancel(paths: paths)
            } catch {
                appendLog("Backend cancel request failed: \(error.localizedDescription)\n")
            }
        } else {
            process?.terminate()
            process = nil
            inputPipe = nil
        }

        cancelPendingRequests(throwing: BackendClientError.cancelled)
        connection?.cancel()
        connection = nil
        inputPipe = nil
        outputBuffer = ""
        isReady = false
        isProcessing = false

        do {
            if let port = paths.tcpPort {
                // Always hard-relaunch after cancel — MLX work often ignores cooperative stop.
                try await ensureTCPBackendRunning(paths: paths, port: port, forceRelaunch: true)
            } else {
                process?.terminate()
                process = nil
                try await start()
            }
            await loadInitialData()
            currentStage = "Ready"
            statusLine = "Cancelled. Backend restarted."
            errorMessage = nil
        } catch {
            errorMessage = "Cancelled, but backend restart failed: \(error.localizedDescription)"
            currentStage = "Backend stopped"
            statusLine = "Backend restart failed"
        }

        isCancelling = false
    }

    func restartBackend() async {
        // Allow restart while not ready; block only mid-cancel lifecycle already owned by cancel.
        if isCancelling, isPerformingBackendLifecycle { return }
        if isProcessing { return }

        let paths = backendPaths ?? resolveBackendPaths()
        backendPaths = paths
        errorMessage = nil
        currentStage = "Restarting backend"
        statusLine = "Restarting backend"
        isReady = false

        cancelPendingRequests(throwing: BackendClientError.cancelled)
        connection?.cancel()
        connection = nil
        inputPipe = nil
        outputBuffer = ""

        do {
            if let port = paths.tcpPort {
                try await ensureTCPBackendRunning(paths: paths, port: port, forceRelaunch: true)
            } else {
                process?.terminate()
                process = nil
                try await start()
            }
            await loadInitialData()
            currentStage = "Ready"
            statusLine = "Backend restarted."
            errorMessage = nil
        } catch {
            errorMessage = "Backend restart failed: \(error.localizedDescription)"
            currentStage = "Backend stopped"
            statusLine = "Backend restart failed"
        }
    }

    private func sendRequest(method: String, params: [String: Any], requestID explicitRequestID: String? = nil) async throws -> [String: Any] {
        guard isReady, inputPipe != nil || connection != nil else {
            throw BackendClientError.notRunning
        }

        let requestID = explicitRequestID ?? nextRequestID()
        let request: [String: Any] = ["id": requestID, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: request)

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestID] = continuation
            var line = data
            line.append(contentsOf: "\n".utf8)
            if let pipe = inputPipe {
                pipe.fileHandleForWriting.write(line)
            } else if let connection = connection {
                connection.send(content: line, completion: .contentProcessed { [weak self] error in
                    guard let error else { return }
                    Task { @MainActor [weak self] in
                        if let continuation = self?.pendingRequests.removeValue(forKey: requestID) {
                            continuation.resume(throwing: BackendClientError.backend(error.localizedDescription))
                        }
                    }
                })
            }
        }
    }

    private func sendOutOfBandCancel(paths: BackendPaths) async throws {
        guard let port = paths.tcpPort,
              let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return
        }

        let requestID = nextRequestID()
        let request: [String: Any] = [
            "id": requestID,
            "method": "cancel",
            "params": ["reason": "User cancelled batch"],
        ]
        var line = try JSONSerialization.data(withJSONObject: request)
        line.append(contentsOf: "\n".utf8)
        let requestLine = line

        let host = NWEndpoint.Host(paths.tcpHost ?? "127.0.0.1")
        let controlConnection = NWConnection(host: host, port: endpointPort, using: .tcp)
        let controlQueue = networkQueue

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var didFinish = false

            func finish(_ result: Result<Void, Error>) {
                guard !didFinish else { return }
                didFinish = true
                controlConnection.cancel()
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            controlConnection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    controlConnection.send(content: requestLine, completion: .contentProcessed { error in
                        if let error {
                            finish(.failure(BackendClientError.backend(error.localizedDescription)))
                        } else {
                            controlQueue.asyncAfter(deadline: .now() + 0.35) {
                                finish(.success(()))
                            }
                        }
                    })
                case .failed(let error):
                    finish(.failure(BackendClientError.backend(error.localizedDescription)))
                default:
                    break
                }
            }

            controlConnection.start(queue: controlQueue)
            controlQueue.asyncAfter(deadline: .now() + 1.0) {
                finish(.success(()))
            }
        }
    }

    private func launchDetachedTCPBackend(paths: BackendPaths, port: Int) throws {
        guard FileManager.default.fileExists(atPath: paths.python) else {
            throw BackendClientError.launchFailed("Python not found at \(paths.python).")
        }
        guard FileManager.default.fileExists(atPath: paths.server) else {
            throw BackendClientError.launchFailed("Backend server not found at \(paths.server).")
        }

        let logURL = URL(fileURLWithPath: paths.logFile)
        try? FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        proc.arguments = [
            "-MPOSIX=setsid",
            "-e",
            "exit 0 if fork; setsid(); exec @ARGV or die $!",
            "/usr/bin/env",
            "PYTHONUNBUFFERED=1",
            "PYTHONPATH=\(paths.pythonPath)",
            "KIRTAN_SPLITTER_MODEL_DIR=\(paths.modelDir)",
            "KIRTAN_SPLITTER_LOG_FILE=\(paths.logFile)",
            "MLX_USE_FAST_SDP=1",
            paths.python,
            paths.server,
            "--model-dir",
            paths.modelDir,
            "--log-file",
            paths.logFile,
            "--tcp-host",
            paths.tcpHost ?? "127.0.0.1",
            "--tcp-port",
            "\(port)",
        ]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            throw BackendClientError.launchFailed("Backend launcher exited with status \(proc.terminationStatus).")
        }
    }

    private func waitForTCPPortToClose(host: String, port: Int, timeoutSeconds: Double, throwOnTimeout: Bool) async throws {
        let startedAt = Date()
        while isTCPPortOpen(host: host, port: port) {
            if Date().timeIntervalSince(startedAt) >= timeoutSeconds {
                if throwOnTimeout {
                    throw BackendClientError.launchFailed(
                        "Backend port \(host):\(port) stayed busy after stop. Try Restart again."
                    )
                }
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func waitForTCPPortToOpen(host: String, port: Int, timeoutSeconds: Double) async throws {
        let startedAt = Date()
        while !isTCPPortOpen(host: host, port: port) {
            if Date().timeIntervalSince(startedAt) >= timeoutSeconds {
                throw BackendClientError.launchFailed(
                    "Backend did not open \(host):\(port) in time."
                )
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        // Brief settle so accept() is ready before the first client connect.
        try await Task.sleep(nanoseconds: 150_000_000)
    }

    private func isTCPPortOpen(host: String, port: Int) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        proc.arguments = ["-z", host, "\(port)"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func terminateRuntimeBackendProcesses(paths: BackendPaths, port: Int, forceKill: Bool = false) {
        let signalArgs = forceKill ? ["-9", "-f"] : ["-f"]
        let pattern = "\(paths.server).*--tcp-port \(port)"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        proc.arguments = signalArgs + [pattern]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()

        // Fallback: kill whoever still holds the listen socket (path-agnostic).
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/bin/bash")
        let signal = forceKill ? "-9" : "-TERM"
        lsof.arguments = [
            "-c",
            "pids=$(/usr/sbin/lsof -nP -iTCP:\(port) -sTCP:LISTEN -t 2>/dev/null); "
                + "[ -n \"$pids\" ] && kill \(signal) $pids 2>/dev/null; true",
        ]
        lsof.standardOutput = FileHandle.nullDevice
        lsof.standardError = FileHandle.nullDevice
        try? lsof.run()
        lsof.waitUntilExit()
    }

    private func receiveFromConnection(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, weak connection] data, _, isComplete, error in
            if let data, !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                Task { @MainActor [weak self] in
                    self?.handleStdout(text)
                }
            }
            if let error {
                Task { @MainActor [weak self] in
                    self?.appendLog("Backend connection receive failed: \(error.localizedDescription)\n")
                }
                return
            }
            guard !isComplete, let connection else { return }
            Task { @MainActor [weak self] in
                self?.receiveFromConnection(connection)
            }
        }
    }

    private func handleStdout(_ text: String) {
        outputBuffer += text
        while let newline = outputBuffer.range(of: "\n") {
            let line = String(outputBuffer[..<newline.lowerBound])
            outputBuffer.removeSubrange(..<newline.upperBound)
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            parseMessage(line)
        }
    }

    private func parseMessage(_ line: String) {
        guard
            let data = line.data(using: .utf8),
            let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            appendLog("Unparsed backend line: \(line)\n")
            return
        }

        let type = message["type"] as? String ?? ""
        let requestID = message["id"] as? String

        switch type {
        case "ready":
            isReady = true
            backendLogPath = message["logFile"] as? String
            statusLine = "Backend ready"
            currentStage = "Ready"
            refreshBackendLogFromFile()

        case "progress":
            currentStage = (message["message"] as? String) ?? (message["stage"] as? String) ?? "Working"
            progress = message["progress"] as? Double ?? progress
            statusLine = currentStage
            if let runtime = message["runtime"] as? [String: Any],
               let snapshot = try? decodeObject(RuntimeSnapshot.self, from: runtime) {
                runtimeStats = snapshot
                if let cacheSummary = snapshot.modelCache {
                    mergeModelCacheSummary(cacheSummary)
                }
            }
            if let requestID, let sink = analysisProgressSinks[requestID] {
                sink(message)
            }
            refreshBackendLogFromFile()

        case "response":
            guard let requestID, let continuation = pendingRequests.removeValue(forKey: requestID) else { return }
            refreshBackendLogFromFile()
            continuation.resume(returning: message["result"] as? [String: Any] ?? [:])

        case "error":
            let backendError = (message["error"] as? String) ?? "Unknown backend error"
            appendLog("Backend error: \(backendError)\n")
            refreshBackendLogFromFile()
            if let requestID, let continuation = pendingRequests.removeValue(forKey: requestID) {
                continuation.resume(throwing: BackendClientError.backend(backendError))
            } else {
                errorMessage = backendError
            }

        default:
            appendLog("Unknown backend message: \(line)\n")
        }
    }

    private func cancelPendingRequests(throwing error: Error) {
        let continuations = pendingRequests.values
        pendingRequests.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }

    private func appendLog(_ text: String) {
        backendLog += text
        if backendLog.count > 20_000 {
            backendLog.removeFirst(backendLog.count - 20_000)
        }
    }

    private func refreshBackendLogFromFile() {
        guard let backendLogPath,
              let text = FileHelpers.readTrailingText(path: backendLogPath, maxBytes: 120_000),
              !text.isEmpty
        else { return }
        backendLog = text
    }

    private func waitUntilReady(timeoutSeconds: Double) async throws {
        let start = Date()
        while !isReady {
            if let connectionFailure {
                let message = connectionFailure.localizedDescription
                self.connectionFailure = nil
                throw BackendClientError.backend("Connection failed: \(message)")
            }
            if Date().timeIntervalSince(start) > timeoutSeconds {
                throw BackendClientError.timeout
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        connectionFailure = nil
    }

    private func nextRequestID() -> String {
        requestCounter += 1
        return "req_\(requestCounter)"
    }

    private func decodeArray<T: Decodable>(_ type: T.Type, from result: [String: Any], key: String) throws -> [T] {
        guard let value = result[key] else {
            throw BackendClientError.invalidResponse("Missing \(key)")
        }
        let data = try JSONSerialization.data(withJSONObject: value)
        return try JSONDecoder().decode([T].self, from: data)
    }

    private func decodeObject<T: Decodable>(_ type: T.Type, from result: [String: Any]) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: result)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func startTelemetryLoop() {
        telemetryTask?.cancel()
        telemetryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await self?.refreshTelemetryIfIdle()
            }
        }
    }

    private func refreshTelemetryIfIdle() async {
        guard isReady, !isProcessing, !isTelemetryRequestInFlight else { return }
        isTelemetryRequestInFlight = true
        defer { isTelemetryRequestInFlight = false }

        do {
            runtimeStats = try await fetchRuntimeStats()
            modelCache = try await fetchModelCache()
        } catch {
            appendLog("Telemetry refresh failed: \(error.localizedDescription)\n")
        }
    }

    private func mergeModelCacheSummary(_ summary: ModelCacheSummary) {
        guard modelCache == nil else { return }
        modelCache = ModelCache(modelDir: summary.modelDir, totalBytes: summary.totalBytes, items: [], groups: [])
    }

    private func resolveBackendPaths() -> BackendPaths {
        let env = ProcessInfo.processInfo.environment
        let info = Bundle.main.infoDictionary ?? [:]
        let bundledProjectRoot = info["AuraSplitterProjectRoot"] as? String
        let bundledPython = info["AuraSplitterPython"] as? String
        let bundledPythonPath = info["AuraSplitterPythonPath"] as? String
        let bundledServer = info["AuraSplitterBackendServer"] as? String
        let bundledBackendLauncher = info["AuraSplitterBackendLauncher"] as? String
        let bundledModelDir = info["AuraSplitterModelDir"] as? String
        let bundledLogFile = info["AuraSplitterLogFile"] as? String
        let bundledTCPHost = info["AuraSplitterBackendHost"] as? String
        let bundledTCPPort = info["AuraSplitterBackendPort"] as? String

        let projectRoot = env["KIRTAN_SPLITTER_PROJECT_ROOT"] ?? bundledProjectRoot ?? FileManager.default.currentDirectoryPath
        let backendDir = URL(fileURLWithPath: projectRoot).appendingPathComponent("backend").path
        let python = env["KIRTAN_SPLITTER_PYTHON"]
            ?? bundledPython
            ?? URL(fileURLWithPath: projectRoot).appendingPathComponent(".venv/bin/python").path
        let server = env["KIRTAN_SPLITTER_BACKEND_SERVER"]
            ?? bundledServer
            ?? URL(fileURLWithPath: backendDir).appendingPathComponent("server.py").path
        let backendLauncher = env["KIRTAN_SPLITTER_BACKEND_LAUNCHER"]
            ?? bundledBackendLauncher
            ?? URL(fileURLWithPath: projectRoot).appendingPathComponent("script/run_backend.sh").path
        let pythonPath = env["KIRTAN_SPLITTER_PYTHONPATH"]
            ?? bundledPythonPath
            ?? [
                backendDir,
                URL(fileURLWithPath: projectRoot).appendingPathComponent(".venv/lib/python3.11/site-packages").path,
            ].joined(separator: ":")
        ModelStoragePaths.prepareApplicationSupportAndMigrateLegacy()
        let defaultModelDir = ModelStoragePaths.defaultModelDirectory()
        let modelDir = env["KIRTAN_SPLITTER_MODEL_DIR"]
            ?? bundledModelDir
            ?? defaultModelDir
        if env["KIRTAN_SPLITTER_MODEL_DIR"] == nil && modelDir == defaultModelDir {
            ModelStoragePaths.prepareDefaultModelDirectoryAndMigrateLegacyCache()
        } else {
            ModelStoragePaths.prepareModelDirectory(modelDir)
        }
        let logFile = env["KIRTAN_SPLITTER_LOG_FILE"]
            ?? bundledLogFile
            ?? ModelStoragePaths.defaultLogFile()
        let runtimeDir = ModelStoragePaths.defaultRuntimeDirectory()
        let tcpHost = env["KIRTAN_SPLITTER_BACKEND_HOST"] ?? bundledTCPHost
        let tcpPort = (env["KIRTAN_SPLITTER_BACKEND_PORT"] ?? bundledTCPPort).flatMap(Int.init)
        return BackendPaths(
            projectRoot: projectRoot,
            backendDir: backendDir,
            python: python,
            pythonPath: pythonPath,
            server: server,
            backendLauncher: backendLauncher,
            modelDir: modelDir,
            logFile: logFile,
            runtimeDir: runtimeDir,
            tcpHost: tcpHost,
            tcpPort: tcpPort
        )
    }
}

private struct BackendPaths {
    let projectRoot: String
    let backendDir: String
    let python: String
    let pythonPath: String
    let server: String
    let backendLauncher: String
    let modelDir: String
    let logFile: String
    let runtimeDir: String
    let tcpHost: String?
    let tcpPort: Int?
}
