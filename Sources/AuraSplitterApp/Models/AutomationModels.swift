import Foundation

// MARK: - Time ranges (exclusion zones)

/// Inclusive-exclusive-ish time range in seconds; always normalized so start < end.
struct AutomationTimeRange: Identifiable, Equatable, Codable, Hashable {
    var id: UUID
    var start: Double
    var end: Double

    init(id: UUID = UUID(), start: Double, end: Double) {
        self.id = id
        self.start = min(start, end)
        self.end = max(start, end)
    }

    var duration: Double { max(0, end - start) }

    var isValid: Bool { end > start + 0.001 }

    func clamped(to duration: Double) -> AutomationTimeRange {
        let d = max(0, duration)
        let s = min(max(0, start), d)
        let e = min(max(0, end), d)
        return AutomationTimeRange(id: id, start: s, end: e)
    }

    /// Merge overlapping/adjacent ranges; returns sorted non-overlapping list.
    static func merge(_ ranges: [AutomationTimeRange], gapTolerance: Double = 0.01) -> [AutomationTimeRange] {
        let valid = ranges.filter(\.isValid).sorted { $0.start < $1.start }
        guard var current = valid.first else { return [] }
        var result: [AutomationTimeRange] = []
        for next in valid.dropFirst() {
            if next.start <= current.end + gapTolerance {
                current = AutomationTimeRange(
                    id: current.id,
                    start: current.start,
                    end: max(current.end, next.end)
                )
            } else {
                result.append(current)
                current = next
            }
        }
        result.append(current)
        return result
    }

    /// Kept segments when exclusions are removed from [0, duration].
    static func keptSegments(
        duration: Double,
        excluding ranges: [AutomationTimeRange]
    ) -> [AutomationTimeRange] {
        let d = max(0, duration)
        guard d > 0 else { return [] }
        let merged = merge(ranges.map { $0.clamped(to: d) })
        var kept: [AutomationTimeRange] = []
        var cursor = 0.0
        for zone in merged {
            if zone.start > cursor + 0.001 {
                kept.append(AutomationTimeRange(start: cursor, end: zone.start))
            }
            cursor = max(cursor, zone.end)
        }
        if cursor < d - 0.001 {
            kept.append(AutomationTimeRange(start: cursor, end: d))
        }
        return kept
    }
}

// MARK: - Track plan

struct AutomationTrackPlan: Identifiable, Equatable, Codable {
    var id: UUID
    /// Bookmark-friendly path string.
    var sourcePath: String
    var displayName: String
    /// Short name for Ready MIX files (e.g. "Main Vocal").
    var shortOutputName: String
    var isSelected: Bool
    /// Regions to REMOVE before separation.
    var exclusionZones: [AutomationTimeRange]
    /// modelPresetID → stem roles to keep (subset of expectedStems).
    var stemSelections: [String: Set<String>]
    var durationSeconds: Double?

    var sourceURL: URL { URL(fileURLWithPath: sourcePath) }

    init(
        id: UUID = UUID(),
        sourceURL: URL,
        shortOutputName: String? = nil,
        isSelected: Bool = true,
        exclusionZones: [AutomationTimeRange] = [],
        stemSelections: [String: Set<String>] = [:],
        durationSeconds: Double? = nil
    ) {
        self.id = id
        self.sourcePath = sourceURL.path
        self.displayName = sourceURL.lastPathComponent
        let base = sourceURL.deletingPathExtension().lastPathComponent
        self.shortOutputName = shortOutputName ?? base
        self.isSelected = isSelected
        self.exclusionZones = exclusionZones
        self.stemSelections = stemSelections
        self.durationSeconds = durationSeconds
    }

    var selectedStemCount: Int {
        stemSelections.values.reduce(0) { $0 + $1.count }
    }

    func hasAnyStemSelection() -> Bool {
        selectedStemCount > 0
    }
}

// MARK: - Job

struct AutomationJob: Equatable, Codable {
    var sourceFolderPath: String?
    var outputFolderPath: String?
    var tracks: [AutomationTrackPlan]
    var processPresetID: String
    var processSettings: ProcessSettingsSnapshot
    /// Model preset currently focused in region editor.
    var regionEditorTrackID: UUID?

    var sourceFolderURL: URL? {
        sourceFolderPath.map { URL(fileURLWithPath: $0) }
    }

    var outputFolderURL: URL? {
        outputFolderPath.map { URL(fileURLWithPath: $0) }
    }

    var selectedTracks: [AutomationTrackPlan] {
        tracks.filter(\.isSelected)
    }

    /// Default Ready MIX next to source folder.
    static func defaultOutputFolder(for sourceFolder: URL) -> URL {
        sourceFolder.appendingPathComponent("Ready MIX", isDirectory: true)
    }

    func estimatedWorkUnitCount() -> Int {
        selectedTracks.reduce(0) { total, track in
            let modelJobs = track.stemSelections.values.filter { !$0.isEmpty }.count
            // 1 prepare + N separates
            return total + 1 + modelJobs
        }
    }
}

// MARK: - Wizard step

enum AutomationWizardStep: Int, CaseIterable, Identifiable, Comparable {
    case source = 0
    case regions = 1
    case matrix = 2
    case run = 3

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .source: return "Source"
        case .regions: return "Regions"
        case .matrix: return "Stems"
        case .run: return "Run"
        }
    }

    var subtitle: String {
        switch self {
        case .source: return "Folder & tracks"
        case .regions: return "Cut out unwanted parts"
        case .matrix: return "Models & output names"
        case .run: return "Ready MIX & process"
        }
    }

    static func < (lhs: AutomationWizardStep, rhs: AutomationWizardStep) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var next: AutomationWizardStep? {
        AutomationWizardStep(rawValue: rawValue + 1)
    }

    var previous: AutomationWizardStep? {
        AutomationWizardStep(rawValue: rawValue - 1)
    }
}

// MARK: - Run progress

enum AutomationRunPhase: Equatable {
    case idle
    case running
    case completed
    case failed
    case cancelled
}

struct AutomationRunProgress: Equatable {
    var phase: AutomationRunPhase = .idle
    var completedUnits: Int = 0
    var totalUnits: Int = 0
    var currentMessage: String = ""
    var errors: [String] = []
    var producedFiles: [String] = []

    var fraction: Double {
        guard totalUnits > 0 else { return 0 }
        return min(1, Double(completedUnits) / Double(totalUnits))
    }
}

// MARK: - Final file naming

enum AutomationNaming {
    /// Single selected stem → `Short.wav`; multiple → `Short_stem.wav`.
    static func finalFileName(shortOutputName: String, stem: String, stemCount: Int, ext: String = "wav") -> String {
        let base = sanitize(shortOutputName)
        let stemPart = sanitize(stem)
        if stemCount <= 1 {
            return "\(base).\(ext)"
        }
        return "\(base)_\(stemPart).\(ext)"
    }

    static func sanitize(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = trimmed.components(separatedBy: invalid).joined(separator: "-")
        return cleaned.isEmpty ? "Untitled" : cleaned
    }
}
