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
    var performanceFlags: [String: Bool]

    init(settings: SeparationSettings) {
        outputFormat = settings.outputFormat
        speedMode = settings.speedMode
        chunkDuration = settings.chunkDuration
        mdxcSegmentSize = settings.mdxcSegmentSize
        mdxcOverlap = settings.mdxcOverlap
        mdxcBatchSize = settings.mdxcBatchSize
        mdxcOverrideModelSegmentSize = settings.mdxcOverrideModelSegmentSize
        saveConvertedSafetensors = settings.saveConvertedSafetensors
        performanceFlags = settings.performanceFlags
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
        settings.performanceFlags = performanceFlags
    }

    // Custom Codable so pre-K1 custom presets (saved without performanceFlags)
    // still decode instead of being dropped on load.
    private enum CodingKeys: String, CodingKey {
        case outputFormat, speedMode, chunkDuration, mdxcSegmentSize, mdxcOverlap
        case mdxcBatchSize, mdxcOverrideModelSegmentSize, saveConvertedSafetensors, performanceFlags
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        outputFormat = try c.decode(String.self, forKey: .outputFormat)
        speedMode = try c.decode(String.self, forKey: .speedMode)
        chunkDuration = try c.decode(Double.self, forKey: .chunkDuration)
        mdxcSegmentSize = try c.decode(Int.self, forKey: .mdxcSegmentSize)
        mdxcOverlap = try c.decode(Int.self, forKey: .mdxcOverlap)
        mdxcBatchSize = try c.decode(Int.self, forKey: .mdxcBatchSize)
        mdxcOverrideModelSegmentSize = try c.decode(Bool.self, forKey: .mdxcOverrideModelSegmentSize)
        saveConvertedSafetensors = try c.decode(Bool.self, forKey: .saveConvertedSafetensors)
        performanceFlags = try c.decodeIfPresent([String: Bool].self, forKey: .performanceFlags) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(outputFormat, forKey: .outputFormat)
        try c.encode(speedMode, forKey: .speedMode)
        try c.encode(chunkDuration, forKey: .chunkDuration)
        try c.encode(mdxcSegmentSize, forKey: .mdxcSegmentSize)
        try c.encode(mdxcOverlap, forKey: .mdxcOverlap)
        try c.encode(mdxcBatchSize, forKey: .mdxcBatchSize)
        try c.encode(mdxcOverrideModelSegmentSize, forKey: .mdxcOverrideModelSegmentSize)
        try c.encode(saveConvertedSafetensors, forKey: .saveConvertedSafetensors)
        try c.encode(performanceFlags, forKey: .performanceFlags)
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
        ProcessSettingsPreset(
            id: "builtin.extreme",
            title: "Extreme 4096",
            snapshot: ProcessSettingsSnapshot(settings: extremeSettings),
            isBuiltIn: true
        ),
        ProcessSettingsPreset(
            id: "metal.fast",
            title: "Metal Fast",
            snapshot: ProcessSettingsSnapshot(settings: metalFastSettings),
            isBuiltIn: true
        ),
        ProcessSettingsPreset(
            id: "metal.max",
            title: "Metal Max",
            snapshot: ProcessSettingsSnapshot(settings: metalMaxSettings),
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

    private static var extremeSettings: SeparationSettings {
        var settings = SeparationSettings()
        settings.mdxcSegmentSize = 4096
        settings.mdxcOverlap = 12
        settings.mdxcBatchSize = 1
        settings.mdxcOverrideModelSegmentSize = true
        settings.speedMode = "latency_safe_v3"
        return settings
    }

    private static var metalFastSettings: SeparationSettings {
        var settings = SeparationSettings()
        settings.mdxcSegmentSize = 512
        settings.mdxcOverlap = 8
        settings.mdxcBatchSize = 1
        settings.mdxcOverrideModelSegmentSize = true
        settings.speedMode = "latency_safe_v3"
        settings.performanceFlags = [
            "experimental_roformer_fast_norm": true,
            "experimental_roformer_grouped_band_split": true,
            "experimental_roformer_grouped_mask_estimator": true,
            "experimental_roformer_fused_overlap_add": true,
            "experimental_flac_fast_write": true,
        ]
        return settings
    }

    private static var metalMaxSettings: SeparationSettings {
        var settings = SeparationSettings()
        settings.mdxcSegmentSize = 1024
        settings.mdxcOverlap = 10
        settings.mdxcBatchSize = 2
        settings.mdxcOverrideModelSegmentSize = true
        settings.speedMode = "latency_safe_v3"
        settings.performanceFlags = [
            "experimental_roformer_fast_norm": true,
            "experimental_roformer_grouped_band_split": true,
            "experimental_roformer_grouped_mask_estimator": true,
            "experimental_roformer_fused_overlap_add": true,
            "experimental_roformer_compile_fullgraph": true,
            "experimental_compile_model_forward": true,
            "experimental_compile_shapeless": true,
            "experimental_roformer_static_compiled_demix": true,
            "experimental_mlx_stream_pipeline": true,
            "experimental_roformer_grouped_weight_cache": true,
            "experimental_roformer_chunk_gather_batching": true,
            "experimental_roformer_ola_simd_tuning": true,
            "experimental_mdxc_defer_batch_eval": true,
            "experimental_mdxc_precompute_gather_idx": true,
            "experimental_vectorized_chunking": true,
            "experimental_flac_fast_write": true,
        ]
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
