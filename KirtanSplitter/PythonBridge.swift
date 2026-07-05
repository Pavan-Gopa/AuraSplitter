// PythonBridge.swift
// Запускает Python backend как subprocess и общается через JSON over stdin/stdout.
// Thread-safe, поддерживает async/await.

import Foundation
import Combine

// MARK: - Типы данных

struct StemResult: Identifiable, Codable {
    let id = UUID()
    var name: String
    var path: String
    
    enum CodingKeys: String, CodingKey {
        case name, path
    }
}

struct SeparationResult {
    let stems: [StemResult]
    let totalTime: Double
}

enum BackendError: Error, LocalizedError {
    case notRunning
    case jsonError(String)
    case backendError(String)
    case timeout
    
    var errorDescription: String? {
        switch self {
        case .notRunning: return "Python backend не запущен"
        case .jsonError(let msg): return "Ошибка JSON: \(msg)"
        case .backendError(let msg): return msg
        case .timeout: return "Таймаут ответа от backend"
        }
    }
}

// MARK: - Bridge

@MainActor
class PythonBridge: ObservableObject {
    
    // MARK: Published state
    @Published var isReady = false
    @Published var currentStage = ""
    @Published var progress: Double = 0.0
    @Published var isProcessing = false
    @Published var errorMessage: String? = nil
    
    // MARK: Private
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var outputBuffer = ""
    
    // Pending requests: id → continuation
    private var pendingRequests: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var requestCounter = 0
    private let queue = DispatchQueue(label: "com.kirtansplitter.bridge", qos: .userInitiated)
    
    // MARK: - Start / Stop
    
    func start() async throws {
        guard !isReady else { return }
        
        let pythonPath = findPython()
        let serverScript = serverScriptPath()
        
        print("Запускаем Python: \(pythonPath)")
        print("Скрипт: \(serverScript)")
        
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = [serverScript]
        proc.environment = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
            "PYTHONUNBUFFERED": "1",  // Важно! Иначе stdout буферизируется
            "MLX_USE_GPU": "1",       // Принудительно Metal GPU
        ]
        
        let inPipe = Pipe()
        let outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = Pipe()  // Подавляем stderr в production
        
        self.process = proc
        self.inputPipe = inPipe
        self.outputPipe = outPipe
        
        // Слушаем вывод асинхронно
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                self?.handleOutput(str)
            }
        }
        
        try proc.run()
        
        // Ждём сигнала готовности от backend
        try await withTimeout(seconds: 30) {
            try await self.waitForReady()
        }
    }
    
    func stop() {
        process?.terminate()
        process = nil
        isReady = false
        outputPipe?.fileHandleForReading.readabilityHandler = nil
    }
    
    // MARK: - API Methods
    
    func ping() async throws -> Bool {
        let result = try await sendRequest(method: "ping", params: [:])
        return (result["status"] as? String) == "ok"
    }
    
    func listModels() async throws -> [[String: Any]] {
        let result = try await sendRequest(method: "list_models", params: [:])
        return result["models"] as? [[String: Any]] ?? []
    }
    
    func separate(
        inputPath: String,
        outputDir: String,
        preset: String = "kirtan",
        enabledStages: [Int]? = nil
    ) async throws -> SeparationResult {
        isProcessing = true
        progress = 0
        currentStage = "Подготовка..."
        defer { isProcessing = false }
        
        var params: [String: Any] = [
            "input_path": inputPath,
            "output_dir": outputDir,
            "preset": preset,
        ]
        if let stages = enabledStages {
            params["enabled_stages"] = stages
        }
        
        let result = try await sendRequest(method: "separate", params: params)
        
        guard let stemsDict = result["stems"] as? [String: String] else {
            throw BackendError.backendError("Неверный формат ответа")
        }
        
        let totalTime = result["total_time"] as? Double ?? 0
        let stems = stemsDict.map { StemResult(name: $0.key, path: $0.value) }
        
        return SeparationResult(stems: stems, totalTime: totalTime)
    }
    
    // MARK: - Internal
    
    private func sendRequest(method: String, params: [String: Any]) async throws -> [String: Any] {
        guard isReady else { throw BackendError.notRunning }
        
        let reqId = nextRequestId()
        let req: [String: Any] = [
            "id": reqId,
            "method": method,
            "params": params,
        ]
        
        return try await withCheckedThrowingContinuation { continuation in
            self.pendingRequests[reqId] = continuation
            self.send(json: req)
        }
    }
    
    private func send(json: [String: Any]) {
        guard let pipe = inputPipe else { return }
        do {
            var data = try JSONSerialization.data(withJSONObject: json)
            data.append(contentsOf: "\n".utf8)
            pipe.fileHandleForWriting.write(data)
        } catch {
            print("Ошибка сериализации JSON: \(error)")
        }
    }
    
    private func handleOutput(_ text: String) {
        outputBuffer += text
        
        // Обрабатываем по строкам
        while let range = outputBuffer.range(of: "\n") {
            let line = String(outputBuffer[..<range.lowerBound])
            outputBuffer.removeSubrange(..<range.upperBound)
            
            guard !line.isEmpty else { continue }
            parseMessage(line)
        }
    }
    
    private func parseMessage(_ line: String) {
        guard
            let data = line.data(using: .utf8),
            let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            print("Не удалось распарсить: \(line)")
            return
        }
        
        let type = msg["type"] as? String ?? ""
        let reqId = msg["id"] as? String
        
        switch type {
        case "ready":
            isReady = true
            
        case "progress":
            if let stage = msg["stage"] as? String {
                currentStage = stage
            }
            if let p = msg["progress"] as? Double {
                progress = p
            }
            
        case "response":
            if let id = reqId, let continuation = pendingRequests.removeValue(forKey: id) {
                let result = msg["result"] as? [String: Any] ?? [:]
                continuation.resume(returning: result)
            }
            
        case "error":
            let errMsg = msg["error"] as? String ?? "Неизвестная ошибка"
            if let id = reqId, let continuation = pendingRequests.removeValue(forKey: id) {
                continuation.resume(throwing: BackendError.backendError(errMsg))
            } else {
                errorMessage = errMsg
            }
            
        default:
            print("Неизвестный тип сообщения: \(type)")
        }
    }
    
    private func waitForReady() async throws {
        while !isReady {
            try await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        }
    }
    
    private func nextRequestId() -> String {
        requestCounter += 1
        return "req_\(requestCounter)"
    }
    
    private func findPython() -> String {
        // Ищем Python с MLX (обычно в homebrew или conda)
        let candidates = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            ProcessInfo.processInfo.environment["PYTHON_PATH"] ?? "",
            "/usr/bin/python3",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) } ?? "/usr/bin/python3"
    }
    
    private func serverScriptPath() -> String {
        // В production — внутри app bundle
        if let bundlePath = Bundle.main.path(forResource: "server", ofType: "py", inDirectory: "backend") {
            return bundlePath
        }
        // В разработке — рядом с проектом
        let devPath = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("backend/server.py")
            .path
        return devPath
    }
    
    // MARK: - Timeout helper
    
    private func withTimeout<T>(seconds: Double, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw BackendError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
