import Foundation

struct ProcessSettingsSnapshot: Codable, Equatable {
    var outputFormat: String
    var speedMode: String
    var chunkDuration: Double
    var mdxcSegmentSize: Int
    var mdxcOverlap: Int
    var mdxcBatchSize: Int
    var mdxcOverrideModelSegmentSize: Bool
    var saveConvertedSafetensors: Bool

    init(settings: SeparationSettings) {
        outputFormat = settings.outputFormat
        speedMode = settings.speedMode
        chunkDuration = settings.chunkDuration
        mdxcSegmentSize = settings.mdxcSegmentSize
        mdxcOverlap = settings.mdxcOverlap
        mdxcBatchSize = settings.mdxcBatchSize
        mdxcOverrideModelSegmentSize = settings.mdxcOverrideModelSegmentSize
        saveConvertedSafetensors = settings.saveConvertedSafetensors
    }

    func apply(to settings: inout SeparationSettings) {
        settings.outputFormat = outputFormat
        settings.speedMode = speedMode
        settings.chunkDuration = chunkDuration
        settings.mdxcSegmentSize = mdxcSegmentSize
        settings.mdxcOverlap = mdxcOverlap
        settings.mdxcBatchSize = mdxcBatchSize
        settings.mdxcOverrideModelSegmentSize = mdxcOverrideModelSegmentSize
        settings.saveConvertedSafetensors = saveConvertedSafetensors
    }
}

struct ProcessSettingsPreset: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    var snapshot: ProcessSettingsSnapshot
    var isBuiltIn: Bool

    static let defaultPresetID = "builtin.default"

    static let builtIn: [ProcessSettingsPreset] = [
        ProcessSettingsPreset(
            id: defaultPresetID,
            title: "Default",
            snapshot: ProcessSettingsSnapshot(settings: SeparationSettings()),
            isBuiltIn: true
        ),
        ProcessSettingsPreset(
            id: "builtin.fast",
            title: "Fast 512",
            snapshot: ProcessSettingsSnapshot(settings: fastSettings),
            isBuiltIn: true
        ),
        ProcessSettingsPreset(
            id: "builtin.heavy",
            title: "Heavy 1024",
            snapshot: ProcessSettingsSnapshot(settings: heavySettings),
            isBuiltIn: true
        ),
    ]

    private static var fastSettings: SeparationSettings {
        var settings = SeparationSettings()
        settings.mdxcSegmentSize = 512
        settings.mdxcOverlap = 8
        settings.mdxcBatchSize = 1
        settings.speedMode = "latency_safe_v3"
        return settings
    }

    private static var heavySettings: SeparationSettings {
        var settings = SeparationSettings()
        settings.mdxcSegmentSize = 1024
        settings.mdxcOverlap = 10
        settings.mdxcBatchSize = 2
        settings.speedMode = "latency_safe_v3"
        return settings
    }
}

final class ProcessSettingsPresetStore: ObservableObject {
    @Published private(set) var presets: [ProcessSettingsPreset]

    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = "KirtanSplitter.customProcessSettingsPresets"
    ) {
        self.defaults = defaults
        self.key = key
        presets = Self.loadPresets(defaults: defaults, key: key)
    }

    func preset(id: String) -> ProcessSettingsPreset? {
        presets.first { $0.id == id }
    }

    @discardableResult
    func saveCustomPreset(named title: String, settings: SeparationSettings) -> ProcessSettingsPreset {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let preset = ProcessSettingsPreset(
            id: "custom.\(UUID().uuidString)",
            title: trimmedTitle.isEmpty ? "Custom \(customPresets.count + 1)" : trimmedTitle,
            snapshot: ProcessSettingsSnapshot(settings: settings),
            isBuiltIn: false
        )
        presets.append(preset)
        persistCustomPresets()
        return preset
    }

    func deleteCustomPreset(id: String) {
        presets.removeAll { $0.id == id && !$0.isBuiltIn }
        persistCustomPresets()
    }

    private var customPresets: [ProcessSettingsPreset] {
        presets.filter { !$0.isBuiltIn }
    }

    private func persistCustomPresets() {
        guard let data = try? JSONEncoder().encode(customPresets) else { return }
        defaults.set(data, forKey: key)
    }

    private static func loadPresets(defaults: UserDefaults, key: String) -> [ProcessSettingsPreset] {
        guard
            let data = defaults.data(forKey: key),
            let customPresets = try? JSONDecoder().decode([ProcessSettingsPreset].self, from: data)
        else {
            return ProcessSettingsPreset.builtIn
        }
        return ProcessSettingsPreset.builtIn + customPresets.filter { !$0.isBuiltIn }
    }
}
