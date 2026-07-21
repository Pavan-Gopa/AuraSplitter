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

    /// Flattened (modelID, stem) pairs currently kept for this track.
    var selectedStemPairs: [(modelID: String, stem: String)] {
        var pairs: [(String, String)] = []
        for (modelID, stems) in stemSelections.sorted(by: { $0.key < $1.key }) {
            for stem in stems.sorted() {
                pairs.append((modelID, stem))
            }
        }
        return pairs
    }
}

// MARK: - Pipeline step 2 (optional second separation)

/// Virtual source for matrix step 2: a kept stem from step 1, shown as `MAIN_V(Vocal)`.
///
/// Runner semantics (when Process is wired):
/// - Original step-1 sources are **never** deleted.
/// - Step-1 stem files are written to a temp/intermediate folder.
/// - Step 2 separates those intermediates into Ready MIX finals.
/// - Intermediate step-1 outputs are deleted after a successful step-2 run.
struct AutomationStep2TrackPlan: Identifiable, Equatable, Codable {
    var id: UUID
    /// Step-1 track that produced this intermediate.
    var parentTrackID: UUID
    var parentShortName: String
    var fromModelID: String
    var fromStem: String
    /// Left-column label, e.g. `MAIN_V(Vocal)`.
    var displayName: String
    /// Final Ready MIX short name for this row’s outputs.
    var shortOutputName: String
    var isSelected: Bool
    /// modelPresetID → stem roles to keep on this intermediate.
    var stemSelections: [String: Set<String>]

    init(
        id: UUID = UUID(),
        parentTrackID: UUID,
        parentShortName: String,
        fromModelID: String,
        fromStem: String,
        displayName: String,
        shortOutputName: String? = nil,
        isSelected: Bool = true,
        stemSelections: [String: Set<String>] = [:]
    ) {
        self.id = id
        self.parentTrackID = parentTrackID
        self.parentShortName = parentShortName
        self.fromModelID = fromModelID
        self.fromStem = fromStem
        self.displayName = displayName
        self.shortOutputName = shortOutputName ?? displayName
        self.isSelected = isSelected
        self.stemSelections = stemSelections
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
    /// Optional second matrix (max 2 pipeline steps). Empty = step 1 only.
    var step2Tracks: [AutomationStep2TrackPlan]
    /// Which matrix the user is editing: 1 or 2.
    var matrixPipelineStep: Int

    init(
        sourceFolderPath: String? = nil,
        outputFolderPath: String? = nil,
        tracks: [AutomationTrackPlan] = [],
        processPresetID: String,
        processSettings: ProcessSettingsSnapshot,
        regionEditorTrackID: UUID? = nil,
        step2Tracks: [AutomationStep2TrackPlan] = [],
        matrixPipelineStep: Int = 1
    ) {
        self.sourceFolderPath = sourceFolderPath
        self.outputFolderPath = outputFolderPath
        self.tracks = tracks
        self.processPresetID = processPresetID
        self.processSettings = processSettings
        self.regionEditorTrackID = regionEditorTrackID
        self.step2Tracks = step2Tracks
        self.matrixPipelineStep = matrixPipelineStep
    }

    // Back-compat: jobs saved before step 2 still decode.
    private enum CodingKeys: String, CodingKey {
        case sourceFolderPath, outputFolderPath, tracks, processPresetID
        case processSettings, regionEditorTrackID, step2Tracks, matrixPipelineStep
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceFolderPath = try c.decodeIfPresent(String.self, forKey: .sourceFolderPath)
        outputFolderPath = try c.decodeIfPresent(String.self, forKey: .outputFolderPath)
        tracks = try c.decodeIfPresent([AutomationTrackPlan].self, forKey: .tracks) ?? []
        processPresetID = try c.decode(String.self, forKey: .processPresetID)
        processSettings = try c.decode(ProcessSettingsSnapshot.self, forKey: .processSettings)
        regionEditorTrackID = try c.decodeIfPresent(UUID.self, forKey: .regionEditorTrackID)
        step2Tracks = try c.decodeIfPresent([AutomationStep2TrackPlan].self, forKey: .step2Tracks) ?? []
        matrixPipelineStep = try c.decodeIfPresent(Int.self, forKey: .matrixPipelineStep) ?? 1
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(sourceFolderPath, forKey: .sourceFolderPath)
        try c.encodeIfPresent(outputFolderPath, forKey: .outputFolderPath)
        try c.encode(tracks, forKey: .tracks)
        try c.encode(processPresetID, forKey: .processPresetID)
        try c.encode(processSettings, forKey: .processSettings)
        try c.encodeIfPresent(regionEditorTrackID, forKey: .regionEditorTrackID)
        try c.encode(step2Tracks, forKey: .step2Tracks)
        try c.encode(matrixPipelineStep, forKey: .matrixPipelineStep)
    }

    var sourceFolderURL: URL? {
        sourceFolderPath.map { URL(fileURLWithPath: $0) }
    }

    var outputFolderURL: URL? {
        outputFolderPath.map { URL(fileURLWithPath: $0) }
    }

    var selectedTracks: [AutomationTrackPlan] {
        tracks.filter(\.isSelected)
    }

    var selectedStep2Tracks: [AutomationStep2TrackPlan] {
        step2Tracks.filter(\.isSelected)
    }

    var hasStep2: Bool { !step2Tracks.isEmpty }

    /// Default Ready MIX next to source folder.
    static func defaultOutputFolder(for sourceFolder: URL) -> URL {
        sourceFolder.appendingPathComponent("Ready MIX", isDirectory: true)
    }

    /// Temp folder for step-1 stem files when a second step is configured.
    static func intermediateFolder(for outputFolder: URL) -> URL {
        outputFolder.appendingPathComponent("_AutomationStep1", isDirectory: true)
    }

    func estimatedWorkUnitCount() -> Int {
        let step1 = selectedTracks.reduce(0) { total, track in
            let modelJobs = track.stemSelections.values.filter { !$0.isEmpty }.count
            return total + 1 + modelJobs
        }
        guard hasStep2 else { return step1 }
        let step2 = selectedStep2Tracks.reduce(0) { total, track in
            let modelJobs = track.stemSelections.values.filter { !$0.isEmpty }.count
            return total + 1 + modelJobs
        }
        return step1 + step2
    }

    /// Build step-2 rows from step-1 kept stems: `ShortName(StemRole)`.
    static func buildStep2Tracks(from step1Tracks: [AutomationTrackPlan]) -> [AutomationStep2TrackPlan] {
        var rows: [AutomationStep2TrackPlan] = []
        var usedNames: [String: Int] = [:]

        for track in step1Tracks where track.isSelected {
            let short = track.shortOutputName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !short.isEmpty else { continue }
            for pair in track.selectedStemPairs {
                let baseLabel = AutomationNaming.intermediateDisplayName(
                    shortOutputName: short,
                    stem: pair.stem
                )
                // Disambiguate if the same short+stem appears from two models.
                let count = usedNames[baseLabel, default: 0]
                usedNames[baseLabel] = count + 1
                let display: String
                if count == 0 {
                    display = baseLabel
                } else {
                    display = "\(baseLabel)_\(count + 1)"
                }
                rows.append(
                    AutomationStep2TrackPlan(
                        parentTrackID: track.id,
                        parentShortName: short,
                        fromModelID: pair.modelID,
                        fromStem: pair.stem,
                        displayName: display,
                        shortOutputName: display,
                        isSelected: true
                    )
                )
            }
        }
        return rows
    }
}

// MARK: - Wizard step

/// Three-step wizard: Input/Output paths → region cuts → stem matrix + Process.
enum AutomationWizardStep: Int, CaseIterable, Identifiable, Comparable {
    case io = 0
    case regions = 1
    case matrix = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .io: return "Input/Output"
        case .regions: return "Regions"
        case .matrix: return "Matrix"
        }
    }

    var subtitle: String {
        switch self {
        case .io: return "Source folder & Ready MIX"
        case .regions: return "Cut out unwanted parts"
        case .matrix: return "Stems & process"
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

enum AutomationProgressItemStatus: Equatable {
    case pending
    case running
    case step1Done
    case done
    case failed
}

/// One planned Ready MIX output shown in the process panel.
struct AutomationProgressItem: Identifiable, Equatable {
    var id: UUID
    /// Final display name (e.g. MAIN_V(Drum).wav or MAIN_V_Lead.wav).
    var title: String
    var status: AutomationProgressItemStatus
    var detail: String?
    /// When this item started running (for per-file wall time).
    var startedAt: Date?
    /// Wall time spent producing this file (set when done/failed).
    var elapsedSeconds: Double?
    /// Wall time for Step 1 only (frozen when step 1 completes for a 2-step item).
    var step1ElapsedSeconds: Double?

    init(
        id: UUID = UUID(),
        title: String,
        status: AutomationProgressItemStatus = .pending,
        detail: String? = nil,
        startedAt: Date? = nil,
        elapsedSeconds: Double? = nil,
        step1ElapsedSeconds: Double? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.detail = detail
        self.startedAt = startedAt
        self.elapsedSeconds = elapsedSeconds
        self.step1ElapsedSeconds = step1ElapsedSeconds
    }
}

struct AutomationRunProgress: Equatable {
    var phase: AutomationRunPhase = .idle
    var completedUnits: Int = 0
    var totalUnits: Int = 0
    /// Short status under the progress bar (uses model display titles, never raw ids).
    var currentMessage: String = ""
    /// Secondary line: "Separating with Aura Pro…" / "Automation Complete".
    var headline: String = ""
    var errors: [String] = []
    var producedFiles: [String] = []
    /// Checklist of planned outputs (green ticks as each file lands).
    var items: [AutomationProgressItem] = []
    /// Wall-clock start of this automation session.
    var sessionStartedAt: Date?
    /// Set when phase leaves `.running` (complete / fail / cancel).
    var sessionFinishedAt: Date?

    var fraction: Double {
        guard totalUnits > 0 else { return 0 }
        return min(1, Double(completedUnits) / Double(totalUnits))
    }

    var doneCount: Int {
        items.filter { $0.status == .done }.count
    }

    /// Session wall time so far (or frozen at finish).
    func sessionElapsedSeconds(now: Date = Date()) -> Double {
        guard let start = sessionStartedAt else { return 0 }
        let end = sessionFinishedAt ?? now
        return max(0, end.timeIntervalSince(start))
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

    /// Step-2 source label: `MAIN_V(Vocal)`, `MAIN_V(Drum)`, …
    static func intermediateDisplayName(shortOutputName: String, stem: String) -> String {
        let base = sanitize(shortOutputName)
        let role = stemRoleShortLabel(stem)
        return "\(base)(\(role))"
    }

    /// Compact role label for parentheses (not the raw stem id).
    static func stemRoleShortLabel(_ stem: String) -> String {
        let kind = stem
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")

        switch kind {
        case "vocals", "vocal":
            return "Vocal"
        case "lead", "lead_vocal", "lead_vocals":
            return "Lead"
        case "back", "back_vocal", "back_vocals", "backing", "backing_vocals", "backing_vocal":
            return "Back"
        case "drums", "drum":
            return "Drum"
        case "kick", "kick_drum", "bd":
            return "Kick"
        case "snare", "snare_drum", "sd":
            return "Snare"
        case "toms", "tom":
            return "Toms"
        case "hh", "hihat", "hi_hat", "hats":
            return "HH"
        case "cymbals", "cymbal", "crash", "ride":
            return "Cymbal"
        case "bass":
            return "Bass"
        case "piano", "keys", "keys_piano":
            return "Piano"
        case "guitar", "guitars", "electric_guitar", "acoustic_guitar":
            return "Guitar"
        case "instrumental", "instruments", "inst":
            return "Inst"
        case "other", "rest":
            return "Other"
        case "no_drums", "nodrums":
            return "NoDrum"
        case "sitar":
            return "Sitar"
        default:
            return sanitize(stem)
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
                .replacingOccurrences(of: " ", with: "")
        }
    }

    static func sanitize(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = trimmed.components(separatedBy: invalid).joined(separator: "-")
        return cleaned.isEmpty ? "Untitled" : cleaned
    }
}
