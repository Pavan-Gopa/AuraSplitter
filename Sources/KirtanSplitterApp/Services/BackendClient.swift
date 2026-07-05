import Foundation

enum BackendClientError: Error, LocalizedError {
    case notRunning
    case launchFailed(String)
    case invalidResponse(String)
    case backend(String)
    case timeout

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
        }
    }
}

@MainActor
final class BackendClient: ObservableObject {
    @Published var isReady = false
    @Published var isProcessing = false
    @Published var progress: Double = 0
    @Published var currentStage = "Backend stopped"
    @Published var statusLine = "Not started"
    @Published var errorMessage: String?
    @Published var backendLog = ""
    @Published var presets: [SeparationPreset] = []
    @Published var models: [SeparatorModel] = []

    private var process: Process?
    private var inputPipe: Pipe?
    private var outputBuffer = ""
    private var pendingRequests: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var requestCounter = 0

    func start() async throws {
        if isReady { return }

        let paths = resolveBackendPaths()
        guard FileManager.default.fileExists(atPath: paths.python) else {
            throw BackendClientError.launchFailed("Python not found at \(paths.python). Run script/setup_backend.sh first.")
        }
        guard FileManager.default.fileExists(atPath: paths.server) else {
            throw BackendClientError.launchFailed("Backend server not found at \(paths.server).")
        }

        currentStage = "Starting backend"
        statusLine = "Launching Python backend"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: paths.python)
        proc.arguments = [paths.server, "--model-dir", paths.modelDir]
        proc.currentDirectoryURL = URL(fileURLWithPath: paths.projectRoot)

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONPATH"] = paths.backendDir
        environment["KIRTAN_SPLITTER_MODEL_DIR"] = paths.modelDir
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

        try await waitUntilReady(timeoutSeconds: 30)
        statusLine = "Backend ready"
    }

    func stop() {
        process?.terminate()
        process = nil
        inputPipe = nil
        pendingRequests.removeAll()
        isReady = false
        isProcessing = false
        statusLine = "Backend stopped"
        currentStage = "Backend stopped"
    }

    func loadInitialData() async {
        do {
            presets = try await listPresets()
            models = try await listModels(limit: 140)
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

    func separate(inputURL: URL, outputDirectory: URL, settings: SeparationSettings) async throws -> SeparationSummary {
        isProcessing = true
        progress = 0
        currentStage = "Preparing"
        statusLine = "Starting separation"
        defer { isProcessing = false }

        var params: [String: Any] = [
            "inputPath": inputURL.path,
            "outputDir": outputDirectory.path,
            "preset": settings.presetID,
            "outputFormat": settings.outputFormat,
            "speedMode": settings.speedMode,
            "saveConvertedSafetensors": settings.saveConvertedSafetensors,
        ]
        if let modelOverride = settings.modelOverride, !modelOverride.isEmpty {
            params["modelFilename"] = modelOverride
        }
        if let chunkDuration = settings.chunkDurationForBackend {
            params["chunkDuration"] = chunkDuration
        }

        let result = try await sendRequest(method: "separate", params: params)
        let summary = try decodeObject(SeparationSummary.self, from: result)
        progress = 1
        currentStage = "Complete"
        statusLine = "Finished in \(String(format: "%.1f", summary.elapsedSeconds))s"
        return summary
    }

    private func sendRequest(method: String, params: [String: Any]) async throws -> [String: Any] {
        guard isReady, let pipe = inputPipe else {
            throw BackendClientError.notRunning
        }

        let requestID = nextRequestID()
        let request: [String: Any] = ["id": requestID, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: request)

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestID] = continuation
            var line = data
            line.append(contentsOf: "\n".utf8)
            pipe.fileHandleForWriting.write(line)
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
            statusLine = "Backend ready"
            currentStage = "Ready"

        case "progress":
            currentStage = (message["message"] as? String) ?? (message["stage"] as? String) ?? "Working"
            progress = message["progress"] as? Double ?? progress
            statusLine = currentStage

        case "response":
            guard let requestID, let continuation = pendingRequests.removeValue(forKey: requestID) else { return }
            continuation.resume(returning: message["result"] as? [String: Any] ?? [:])

        case "error":
            let backendError = (message["error"] as? String) ?? "Unknown backend error"
            if let requestID, let continuation = pendingRequests.removeValue(forKey: requestID) {
                continuation.resume(throwing: BackendClientError.backend(backendError))
            } else {
                errorMessage = backendError
            }

        default:
            appendLog("Unknown backend message: \(line)\n")
        }
    }

    private func appendLog(_ text: String) {
        backendLog += text
        if backendLog.count > 20_000 {
            backendLog.removeFirst(backendLog.count - 20_000)
        }
    }

    private func waitUntilReady(timeoutSeconds: Double) async throws {
        let start = Date()
        while !isReady {
            if Date().timeIntervalSince(start) > timeoutSeconds {
                throw BackendClientError.timeout
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
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

    private func resolveBackendPaths() -> BackendPaths {
        let env = ProcessInfo.processInfo.environment
        let info = Bundle.main.infoDictionary ?? [:]
        let bundledProjectRoot = info["KirtanSplitterProjectRoot"] as? String
        let bundledPython = info["KirtanSplitterPython"] as? String
        let bundledServer = info["KirtanSplitterBackendServer"] as? String
        let bundledModelDir = info["KirtanSplitterModelDir"] as? String

        let projectRoot = env["KIRTAN_SPLITTER_PROJECT_ROOT"] ?? bundledProjectRoot ?? FileManager.default.currentDirectoryPath
        let backendDir = URL(fileURLWithPath: projectRoot).appendingPathComponent("backend").path
        let python = env["KIRTAN_SPLITTER_PYTHON"]
            ?? bundledPython
            ?? URL(fileURLWithPath: projectRoot).appendingPathComponent(".venv/bin/python").path
        let server = env["KIRTAN_SPLITTER_BACKEND_SERVER"]
            ?? bundledServer
            ?? URL(fileURLWithPath: backendDir).appendingPathComponent("server.py").path
        let modelDir = env["KIRTAN_SPLITTER_MODEL_DIR"]
            ?? bundledModelDir
            ?? URL(fileURLWithPath: projectRoot).appendingPathComponent("models").path
        return BackendPaths(
            projectRoot: projectRoot,
            backendDir: backendDir,
            python: python,
            server: server,
            modelDir: modelDir
        )
    }
}

private struct BackendPaths {
    let projectRoot: String
    let backendDir: String
    let python: String
    let server: String
    let modelDir: String
}
