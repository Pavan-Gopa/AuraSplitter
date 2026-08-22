import Foundation

/// Runs Automation: cut regions → separate selected models/stems → Ready MIX (+ optional Step 2).
///
/// Pipeline rules:
/// - Original source files are never deleted.
/// - With Step 2 (default): Step 1 stems land in `_AutomationStep1/` (deleted after success).
///   - Step-2 rows **with** stem picks are re-separated → Ready MIX finals (root).
///   - Step-2 rows **without** further picks are **copied** to Ready MIX as-is.
/// - With Step 2 + **Save Step 1**: `Ready MIX/Step 1/` keeps all Step 1 stems permanently;
///   Step 2 finals go to `Ready MIX/Step 2/`. The temp `_AutomationStep1` folder is not used.
@MainActor
final class AutomationProcessRunner {
    private let backend: BackendClient
    private let processPresetStore: ProcessSettingsPresetStore

    init(backend: BackendClient, processPresetStore: ProcessSettingsPresetStore) {
        self.backend = backend
        self.processPresetStore = processPresetStore
    }

    func run(store: AutomationWizardStore) async throws {
        if let msg = store.validationMessage(for: .matrix) {
            store.stepError = msg
            store.runProgress.phase = .failed
            store.runProgress.currentMessage = msg
            throw AutomationRunnerError.validation(msg)
        }

        guard let outputDir = store.job.outputFolderURL else {
            throw AutomationRunnerError.validation("No Ready MIX folder.")
        }

        let fm = FileManager.default
        try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let hasStep2 = store.job.hasStep2
        let saveStep1 = hasStep2 && store.job.saveStep1Outputs
        // Where Step 1 stems live (input to Step 2).
        let intermediateDir: URL = saveStep1
            ? AutomationJob.step1ArchiveFolder(for: outputDir)
            : AutomationJob.intermediateFolder(for: outputDir)
        // Where Step 2 / passthrough finals land.
        let finalsDir: URL = saveStep1
            ? AutomationJob.step2ArchiveFolder(for: outputDir)
            : outputDir
        if hasStep2 {
            if saveStep1 {
                // Fresh archive folders for this run (keep Ready MIX root clean).
                try? fm.removeItem(at: intermediateDir)
                try? fm.removeItem(at: finalsDir)
                try fm.createDirectory(at: intermediateDir, withIntermediateDirectories: true)
                try fm.createDirectory(at: finalsDir, withIntermediateDirectories: true)
            } else {
                try? fm.removeItem(at: intermediateDir)
                try fm.createDirectory(at: intermediateDir, withIntermediateDirectories: true)
            }
        }

        // Re-load process preset from store so Matrix choice (e.g. Max_off) is exact,
        // not a stale snapshot if the user changed presets mid-wizard.
        if let preset = processPresetStore.preset(id: store.job.processPresetID) {
            store.job.processPresetID = preset.id
            store.job.processSettings = preset.snapshot
        }
        var settings = store.processSettingsAsSeparation
        let processPreset = processPresetStore.preset(id: store.job.processPresetID)

        let step1Tracks = store.job.selectedTracks
        let step2All = store.job.step2Tracks
        let step2Further = step2All.filter { $0.isSelected && $0.hasAnyStemSelection() }
        let step2Passthrough = step2All.filter { !($0.isSelected && $0.hasAnyStemSelection()) }

        // Work units: cut + one separate per model used in step 1, then step-2 further models only.
        // Passthrough stems are exported *during* step 1 (no extra long jobs).
        var total = 0
        for track in step1Tracks {
            total += 1 // prepare/cut
            total += track.stemSelections.values.filter { !$0.isEmpty }.count
        }
        if hasStep2 {
            for track in step2Further {
                total += track.stemSelections.values.filter { !$0.isEmpty }.count
            }
        }
        total = max(total, 1)

        let plannedItems = planOutputItems(
            hasStep2: hasStep2,
            saveStep1: saveStep1,
            step1Tracks: step1Tracks,
            step2Further: step2Further,
            step2Passthrough: step2Passthrough
        )

        let presetLabel = processPreset?.title ?? store.job.processPresetID
        let settingsHint =
            "\(presetLabel) · seg \(settings.mdxcSegmentSize) · ov \(settings.mdxcOverlap) · batch \(settings.mdxcBatchSize) · \(settings.speedMode)"
        store.runProgress = AutomationRunProgress(
            phase: .running,
            completedUnits: 0,
            totalUnits: total,
            currentMessage: settingsHint,
            headline: "Running automation…",
            errors: [],
            producedFiles: [],
            items: plannedItems,
            sessionStartedAt: Date(),
            sessionFinishedAt: nil
        )
        store.stepError = nil

        var tempsToDelete: [URL] = []
        defer {
            for url in tempsToDelete {
                try? fm.removeItem(at: url)
            }
        }

        /// key: parentTrackID|modelID|stem → intermediate file URL (only stems needed for Step 2 further)
        var intermediateFiles: [String: URL] = [:]
        var step1StemOutputs: [Step1StemOutput] = []
        /// Keys already exported to Ready MIX during Step 1 (passthrough).
        var exportedPassthroughKeys = Set<String>()

        // ─── STEP 1 ───────────────────────────────────────────────
        // For each stem:
        //   • needed again in Step 2 → keep only in intermediate folder
        //   • not in Step 2 further (Drum etc.) → write Ready MIX NOW + green check immediately
        for track in step1Tracks {
            try Task.checkCancellation()

            store.runProgress.currentMessage = "Step 1 · cut · \(track.displayName)"
            store.runProgress.headline = "Preparing \(track.displayName)…"
            let prepared: (url: URL, isTemporary: Bool)
            do {
                prepared = try AutomationAudioCutter.prepareInput(
                    source: track.sourceURL,
                    exclusionZones: track.exclusionZones,
                    durationSeconds: track.durationSeconds
                )
            } catch {
                store.runProgress.errors.append("\(track.displayName): \(error.localizedDescription)")
                bump(store)
                continue
            }
            if prepared.isTemporary { tempsToDelete.append(prepared.url) }
            bump(store)

            let selectedPairs = track.selectedStemPairs
            let stemCountForNaming = Set(selectedPairs.map(\.stem)).count
            let byModel = Dictionary(grouping: selectedPairs, by: \.modelID)

            for (modelID, pairs) in byModel.sorted(by: { $0.key < $1.key }) {
                try Task.checkCancellation()
                let modelTitle = displayTitle(forModelID: modelID)
                store.runProgress.currentMessage = "Step 1 · \(track.displayName) · \(modelTitle)"
                store.runProgress.headline = "Separating with \(modelTitle)…"
                settings.presetID = modelID
                // Keep modelOverride clear so the chosen matrix model is the one that runs.
                settings.modelOverride = nil

                // Work next to Ready MIX (same volume → hardlink = bit-identical, no re-encode).
                // Avoid /tmp copies that can force extra I/O and quality loss paths.
                let workDir = outputDir
                    .appendingPathComponent("_work", isDirectory: true)
                    .appendingPathComponent(track.id.uuidString, isDirectory: true)
                    .appendingPathComponent(modelID, isDirectory: true)
                try? fm.removeItem(at: workDir)
                try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
                tempsToDelete.append(workDir)

                // Mark expected Ready MIX names running so the checklist animates + clocks start.
                for pair in pairs {
                    let matchKey: String
                    if hasStep2 {
                        let fr = step2Further.first {
                            $0.parentTrackID == track.id
                                && normalizeStem($0.fromStem) == normalizeStem(pair.stem)
                        }
                        matchKey = fr?.shortOutputName ?? track.shortOutputName
                    } else {
                        matchKey = AutomationNaming.finalFileName(
                            shortOutputName: track.shortOutputName,
                            stem: pair.stem,
                            stemCount: stemCountForNaming
                        ).replacingOccurrences(of: ".wav", with: "")
                    }
                    markItemRunning(store, titleContains: matchKey)
                }
                let unitStartedAt = Date()

                do {
                    let summary = try await backend.separate(
                        inputURL: prepared.url,
                        outputDirectory: workDir,
                        settings: settings,
                        processPreset: processPreset
                    )

                    if summary.files.isEmpty {
                        store.runProgress.errors.append(
                            "\(track.displayName) / \(modelTitle): separation returned 0 files"
                        )
                    }

                    // Two-pass stem→file assignment: name match first, positional fallback second.
                    var claimedIndices = Set<Int>()
                    var assignments: [(pair: (modelID: String, stem: String), file: StemFile?)] = []

                    for pair in pairs {
                        if let (idx, file) = matchStemIndexed(pair.stem, in: summary.files, modelID: modelID, excluding: claimedIndices) {
                            claimedIndices.insert(idx)
                            assignments.append((pair, file))
                        } else {
                            assignments.append((pair, nil))
                        }
                    }
                    let unclaimed = summary.files.enumerated()
                        .filter { !claimedIndices.contains($0.offset) }
                        .map(\.element)
                    var fallbackIter = unclaimed.makeIterator()
                    for i in assignments.indices where assignments[i].file == nil {
                        assignments[i].file = fallbackIter.next()
                    }

                    for entry in assignments {
                        let pair = entry.pair
                        guard let stemFile = entry.file else {
                            let available = summary.files.map(\.stem).joined(separator: ", ")
                            store.runProgress.errors.append(
                                "\(track.displayName): stem \u{201c}\(pair.stem)\u{201d} not in [\(available)] from \(modelTitle)"
                            )
                            continue
                        }
                        let src = URL(fileURLWithPath: stemFile.path)
                        let display = AutomationNaming.intermediateDisplayName(
                            shortOutputName: track.shortOutputName,
                            stem: pair.stem
                        )

                        if !hasStep2 {
                            let fileName = AutomationNaming.finalFileName(
                                shortOutputName: track.shortOutputName,
                                stem: pair.stem,
                                stemCount: stemCountForNaming
                            )
                            let dest = outputDir.appendingPathComponent(fileName)
                            try linkOrCopy(from: src, to: dest)
                            markProduced(store, path: dest.path, title: fileName, unitStartedAt: unitStartedAt)
                            continue
                        }

                        let idKey = intermediateKey(
                            parentID: track.id,
                            modelID: pair.modelID,
                            stem: pair.stem
                        )
                        let furtherRow = step2Further.first {
                            $0.parentTrackID == track.id
                                && normalizeStem($0.fromStem) == normalizeStem(pair.stem)
                                && ($0.fromModelID == pair.modelID
                                    || step2Further.filter {
                                        $0.parentTrackID == track.id
                                            && normalizeStem($0.fromStem) == normalizeStem(pair.stem)
                                    }.count == 1)
                        }
                        let passRow = step2Passthrough.first {
                            $0.parentTrackID == track.id
                                && normalizeStem($0.fromStem) == normalizeStem(pair.stem)
                        }

                        if let fr = furtherRow {
                            // Saved Step 1: human name MAIN_V(Vocal).wav; temp mode keeps model id.
                            let destName = saveStep1
                                ? uniqueName(
                                    preferred: AutomationNaming.sanitize(display) + ".wav",
                                    in: intermediateDir,
                                    fallbackTag: pair.modelID
                                )
                                : AutomationNaming.sanitize(display) + "_\(pair.modelID).wav"
                            let dest = intermediateDir.appendingPathComponent(destName)
                            try linkOrCopy(from: src, to: dest)
                            intermediateFiles[idKey] = dest
                            step1StemOutputs.append(
                                Step1StemOutput(
                                    parentID: track.id,
                                    modelID: pair.modelID,
                                    stem: pair.stem,
                                    displayName: display,
                                    url: dest
                                )
                            )
                            if saveStep1 {
                                // Also list Step 1 archives in the status checklist.
                                markProduced(store, path: dest.path, title: "Step 1/\(destName)", unitStartedAt: unitStartedAt)
                            } else {
                                markStep1Done(store, titleContains: fr.shortOutputName, unitStartedAt: unitStartedAt)
                            }
                        } else {
                            let s2 = passRow
                            let destName = s2.map { finalPassthroughName($0) }
                                ?? (AutomationNaming.sanitize(display) + ".wav")
                            // Passthrough: Step 1 only (no second split). Save with Step 1 folder if archiving.
                            let passthroughDir = saveStep1 ? intermediateDir : finalsDir
                            let dest = passthroughDir.appendingPathComponent(destName)
                            try linkOrCopy(from: src, to: dest)
                            let listTitle = saveStep1 ? "Step 1/\(destName)" : destName
                            markProduced(store, path: dest.path, title: listTitle, unitStartedAt: unitStartedAt)
                            exportedPassthroughKeys.insert(idKey)
                            exportedPassthroughKeys.insert(
                                parentStemKey(parentID: track.id, stem: pair.stem)
                            )
                            store.runProgress.currentMessage = "Ready \u{00b7} \(listTitle)"
                        }
                    }
                } catch is CancellationError {
                    store.runProgress.phase = .cancelled
                    store.runProgress.headline = "Cancelled"
                    store.runProgress.currentMessage = "Cancelled by user"
                    finishSessionClock(store)
                    throw CancellationError()
                } catch BackendClientError.cancelled {
                    store.runProgress.phase = .cancelled
                    store.runProgress.headline = "Cancelled"
                    store.runProgress.currentMessage = "Cancelled by user"
                    finishSessionClock(store)
                    throw CancellationError()
                } catch {
                    store.runProgress.errors.append(
                        "\(track.displayName) / \(displayTitle(forModelID: modelID)): \(error.localizedDescription)"
                    )
                    for pair in pairs {
                        let planned = AutomationNaming.finalFileName(
                            shortOutputName: track.shortOutputName,
                            stem: pair.stem,
                            stemCount: stemCountForNaming
                        )
                        markItemFailed(store, titleContains: planned.replacingOccurrences(of: ".wav", with: ""))
                    }
                }
                bump(store)
            }
        }

        // ─── STEP 2 (only rows that need a second separation) ─────
        if hasStep2 {
            let readyCount = store.runProgress.doneCount
            store.runProgress.currentMessage =
                readyCount > 0
                ? "\(readyCount) file(s) ready · starting Step 2…"
                : "Starting Step 2…"
            store.runProgress.headline = step2Further.isEmpty
                ? "Automation Complete"
                : "Step 2…"

            for s2 in step2Further {
                try Task.checkCancellation()
                store.runProgress.currentMessage = "Step 2 · \(s2.displayName)"
                store.runProgress.headline = "Step 2 · \(s2.displayName)"
                markItemRunning(store, titleContains: s2.shortOutputName)

                guard let inputURL = resolveIntermediate(
                    s2: s2,
                    map: intermediateFiles,
                    outputs: step1StemOutputs,
                    dir: intermediateDir
                ) else {
                    store.runProgress.errors.append(
                        "Step 2: missing Step 1 file for \(s2.displayName) (stem \(s2.fromStem))"
                    )
                    markItemFailed(store, titleContains: s2.shortOutputName)
                    continue
                }

                let pairs = s2.stemSelections
                    .sorted(by: { $0.key < $1.key })
                    .flatMap { modelID, stems in stems.sorted().map { (modelID, $0) } }
                let stemCountForNaming = max(1, Set(pairs.map(\.1)).count)
                let byModel = Dictionary(grouping: pairs, by: \.0)
                var producedForThisRow = 0

                for (modelID, modelPairs) in byModel.sorted(by: { $0.key < $1.key }) {
                    try Task.checkCancellation()
                    let modelTitle = displayTitle(forModelID: modelID)
                    store.runProgress.currentMessage = "Step 2 · \(s2.displayName) · \(modelTitle)"
                    store.runProgress.headline = "Separating with \(modelTitle)…"
                    settings.presetID = modelID
                    settings.modelOverride = nil

                    let workDir = outputDir
                        .appendingPathComponent("_work", isDirectory: true)
                        .appendingPathComponent("s2_\(s2.id.uuidString)", isDirectory: true)
                        .appendingPathComponent(modelID, isDirectory: true)
                    try? fm.removeItem(at: workDir)
                    try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
                    tempsToDelete.append(workDir)
                    let unitStartedAt = Date()

                    do {
                        let summary = try await backend.separate(
                            inputURL: inputURL,
                            outputDirectory: workDir,
                            settings: settings,
                            processPreset: processPreset
                        )
                        // Claim each engine file at most once — otherwise "other" can hardlink
                        // the same path as "back-vocal" (identical Ready MIX twins).
                        var claimedIndices = Set<Int>()
                        var assignments: [(stem: String, file: StemFile?)] = []
                        for (_, stem) in modelPairs {
                            if let (idx, file) = matchStemIndexed(
                                stem,
                                in: summary.files,
                                modelID: modelID,
                                excluding: claimedIndices
                            ) {
                                claimedIndices.insert(idx)
                                assignments.append((stem, file))
                            } else {
                                assignments.append((stem, nil))
                            }
                        }
                        let unclaimed = summary.files.enumerated()
                            .filter { !claimedIndices.contains($0.offset) }
                            .map(\.element)
                        var fallbackIter = unclaimed.makeIterator()
                        for i in assignments.indices where assignments[i].file == nil {
                            assignments[i].file = fallbackIter.next()
                        }

                        for entry in assignments {
                            let stem = entry.stem
                            guard let stemFile = entry.file else {
                                let available = summary.files.map(\.stem).joined(separator: ", ")
                                store.runProgress.errors.append(
                                    "\(s2.displayName): stem “\(stem)” not in [\(available)] from \(modelTitle)"
                                )
                                continue
                            }
                            let src = URL(fileURLWithPath: stemFile.path)
                            let fileName = AutomationNaming.finalFileName(
                                shortOutputName: s2.shortOutputName,
                                stem: stem,
                                stemCount: stemCountForNaming
                            )
                            let dest = finalsDir.appendingPathComponent(fileName)
                            try linkOrCopy(from: src, to: dest)
                            let listTitle = saveStep1 ? "Step 2/\(fileName)" : fileName
                            markProduced(store, path: dest.path, title: listTitle, unitStartedAt: unitStartedAt)
                            producedForThisRow += 1
                        }
                    } catch is CancellationError {
                        store.runProgress.phase = .cancelled
                        store.runProgress.headline = "Cancelled"
                        finishSessionClock(store)
                        throw CancellationError()
                    } catch BackendClientError.cancelled {
                        store.runProgress.phase = .cancelled
                        store.runProgress.headline = "Cancelled"
                        finishSessionClock(store)
                        throw CancellationError()
                    } catch {
                        store.runProgress.errors.append(
                            "Step 2 \(s2.displayName) / \(displayTitle(forModelID: modelID)): \(error.localizedDescription)"
                        )
                    }
                    bump(store)
                }

                if producedForThisRow == 0 {
                    let destName = finalPassthroughName(s2)
                    let dest = finalsDir.appendingPathComponent(destName)
                    do {
                        try linkOrCopy(from: inputURL, to: dest)
                        let listTitle = saveStep1 ? "Step 2/\(destName)" : destName
                        markProduced(store, path: dest.path, title: listTitle)
                        store.runProgress.errors.append(
                            "\(s2.displayName): Step 2 produced no stems — kept Step 1 file"
                        )
                    } catch {
                        markItemFailed(store, titleContains: s2.shortOutputName)
                        store.runProgress.errors.append(
                            "\(s2.displayName): could not keep intermediate (\(error.localizedDescription))"
                        )
                    }
                }
            }

            // Safety: any remaining planned passthrough still pending (Step 1 miss).
            for s2 in step2Passthrough {
                let key = parentStemKey(parentID: s2.parentTrackID, stem: s2.fromStem)
                if exportedPassthroughKeys.contains(key) { continue }
                if store.runProgress.items.contains(where: {
                    $0.status == .done
                        && $0.title.localizedCaseInsensitiveContains(
                            s2.shortOutputName.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                }) {
                    continue
                }
                store.runProgress.errors.append(
                    "Missing Step 1 output for \(s2.displayName)"
                )
                markItemFailed(store, titleContains: s2.shortOutputName)
            }

            // Only wipe hidden temp intermediates — never delete "Step 1" archive.
            if !saveStep1 {
                try? fm.removeItem(at: intermediateDir)
            }
        }

        if store.runProgress.phase == .cancelled {
            store.runProgress.headline = "Cancelled"
            store.runProgress.currentMessage = "Cancelled by user"
            finishSessionClock(store)
            return
        }

        let n = store.runProgress.producedFiles.count
        if n == 0 {
            store.runProgress.phase = .failed
            store.runProgress.headline = "Automation failed"
            store.runProgress.currentMessage = store.runProgress.errors.first ?? "No files produced"
            // Keep errors on the status panel only — no red footer spam.
            store.stepError = nil
        } else {
            store.runProgress.phase = .completed
            store.runProgress.headline = "Automation Complete"
            if saveStep1 {
                store.runProgress.currentMessage =
                    "\(n) file(s) · Step 1 + Step 2 kept under Ready MIX"
            } else {
                store.runProgress.currentMessage = "\(n) file(s) in Ready MIX"
            }
            // Mark any leftover pending items done if file exists.
            for i in store.runProgress.items.indices {
                if store.runProgress.items[i].status == .pending
                    || store.runProgress.items[i].status == .running
                    || store.runProgress.items[i].status == .step1Done {
                    store.runProgress.items[i].status = .done
                }
            }
            store.stepError = nil
        }
        finishSessionClock(store)
    }

    private struct Step1StemOutput {
        var parentID: UUID
        var modelID: String
        var stem: String
        var displayName: String
        var url: URL
    }

    // MARK: - Helpers

    private func bump(_ store: AutomationWizardStore) {
        store.runProgress.completedUnits = min(
            store.runProgress.completedUnits + 1,
            store.runProgress.totalUnits
        )
    }

    private func displayTitle(forModelID id: String) -> String {
        if let title = backend.presets.first(where: { $0.id == id })?.title, !title.isEmpty {
            return title
        }
        // Never surface raw legacy ids like "kirtan_pro" in the UI.
        let cleaned = id
            .replacingOccurrences(of: "kirtan_", with: "aura_", options: .caseInsensitive)
            .replacingOccurrences(of: "_", with: " ")
        return cleaned.capitalized
    }

    private func planOutputItems(
        hasStep2: Bool,
        saveStep1: Bool,
        step1Tracks: [AutomationTrackPlan],
        step2Further: [AutomationStep2TrackPlan],
        step2Passthrough: [AutomationStep2TrackPlan]
    ) -> [AutomationProgressItem] {
        var items: [AutomationProgressItem] = []
        var seen = Set<String>()

        func add(_ title: String) {
            let t = title.hasSuffix(".wav") ? title : title + ".wav"
            guard seen.insert(t).inserted else { return }
            items.append(AutomationProgressItem(title: t, status: .pending))
        }

        if hasStep2 {
            // Passthrough stems are only Step 1 outputs (no second split).
            for s2 in step2Passthrough {
                let name = finalPassthroughName(s2)
                add(saveStep1 ? "Step 1/\(name)" : name)
            }
            // Further rows: Step 1 intermediate + Step 2 finals when archiving.
            for s2 in step2Further {
                if saveStep1 {
                    // Display is already `MAIN_V(Vocal)`-style.
                    add("Step 1/\(AutomationNaming.sanitize(s2.displayName)).wav")
                }
                let pairs = s2.stemSelections.values.flatMap { $0 }
                let count = max(1, Set(pairs).count)
                if count <= 1, let only = pairs.first {
                    let name = AutomationNaming.finalFileName(
                        shortOutputName: s2.shortOutputName,
                        stem: only,
                        stemCount: 1
                    )
                    add(saveStep1 ? "Step 2/\(name)" : name)
                } else if count <= 1 {
                    let name = finalPassthroughName(s2)
                    add(saveStep1 ? "Step 2/\(name)" : name)
                } else {
                    for stem in pairs.sorted() {
                        let name = AutomationNaming.finalFileName(
                            shortOutputName: s2.shortOutputName,
                            stem: stem,
                            stemCount: count
                        )
                        add(saveStep1 ? "Step 2/\(name)" : name)
                    }
                }
            }
        } else {
            for track in step1Tracks {
                let pairs = track.selectedStemPairs
                let count = Set(pairs.map(\.stem)).count
                for pair in pairs {
                    add(AutomationNaming.finalFileName(
                        shortOutputName: track.shortOutputName,
                        stem: pair.stem,
                        stemCount: count
                    ))
                }
            }
        }
        return items
    }

    private func markProduced(
        _ store: AutomationWizardStore,
        path: String,
        title: String,
        unitStartedAt: Date? = nil
    ) {
        store.runProgress.producedFiles.append(path)
        let bare = title.hasSuffix(".wav") ? title : title + ".wav"
        let now = Date()
        if let idx = store.runProgress.items.firstIndex(where: {
            $0.title.caseInsensitiveCompare(bare) == .orderedSame
                || bare.localizedCaseInsensitiveContains(
                    $0.title.replacingOccurrences(of: ".wav", with: "")
                )
        }) {
            let started = store.runProgress.items[idx].startedAt ?? unitStartedAt
            store.runProgress.items[idx].status = .done
            store.runProgress.items[idx].title = bare
            store.runProgress.items[idx].elapsedSeconds = elapsedSince(started, now: now)
        } else {
            store.runProgress.items.append(
                AutomationProgressItem(
                    title: bare,
                    status: .done,
                    elapsedSeconds: elapsedSince(unitStartedAt, now: now)
                )
            )
        }
    }

    private func markItemRunning(_ store: AutomationWizardStore, titleContains: String) {
        let key = titleContains.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        if let idx = store.runProgress.items.firstIndex(where: {
            $0.title.localizedCaseInsensitiveContains(key)
                && ($0.status == .pending || $0.status == .step1Done)
        }) {
            store.runProgress.items[idx].status = .running
            store.runProgress.items[idx].startedAt = Date()
        }
    }

    private func markItemFailed(_ store: AutomationWizardStore, titleContains: String) {
        let key = titleContains.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let now = Date()
        if let idx = store.runProgress.items.firstIndex(where: {
            $0.title.localizedCaseInsensitiveContains(key) && $0.status != .done
        }) {
            let started = store.runProgress.items[idx].startedAt
            store.runProgress.items[idx].status = .failed
            store.runProgress.items[idx].elapsedSeconds = elapsedSince(started, now: now)
        }
    }

    private func markStep1Done(_ store: AutomationWizardStore, titleContains: String, unitStartedAt: Date? = nil) {
        let key = titleContains.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let now = Date()
        for idx in store.runProgress.items.indices where
            store.runProgress.items[idx].title.localizedCaseInsensitiveContains(key)
            && store.runProgress.items[idx].status == .running
        {
            let started = store.runProgress.items[idx].startedAt ?? unitStartedAt
            store.runProgress.items[idx].status = .step1Done
            store.runProgress.items[idx].step1ElapsedSeconds = elapsedSince(started, now: now)
            store.runProgress.items[idx].startedAt = nil
        }
    }

    private func elapsedSince(_ started: Date?, now: Date = Date()) -> Double? {
        guard let started else { return nil }
        return max(0, now.timeIntervalSince(started))
    }

    private func finishSessionClock(_ store: AutomationWizardStore) {
        if store.runProgress.sessionFinishedAt == nil {
            store.runProgress.sessionFinishedAt = Date()
        }
    }

    /// Ready MIX name for a Step-1 stem kept without further split.
    private func finalPassthroughName(_ s2: AutomationStep2TrackPlan) -> String {
        var base = s2.shortOutputName.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = s2.displayName }
        base = AutomationNaming.sanitize(base)
        if base.lowercased().hasSuffix(".wav") { return base }
        return base + ".wav"
    }

    private func intermediateKey(parentID: UUID, modelID: String, stem: String) -> String {
        "\(parentID.uuidString)|\(modelID)|\(normalizeStem(stem))"
    }

    /// Prefer `preferred`; if it already exists in `dir`, append `_fallbackTag` before extension.
    private func uniqueName(preferred: String, in dir: URL, fallbackTag: String) -> String {
        let fm = FileManager.default
        let preferredURL = dir.appendingPathComponent(preferred)
        if !fm.fileExists(atPath: preferredURL.path) {
            return preferred
        }
        let base = (preferred as NSString).deletingPathExtension
        let ext = (preferred as NSString).pathExtension
        let tag = AutomationNaming.sanitize(fallbackTag)
        let alt = ext.isEmpty ? "\(base)_\(tag)" : "\(base)_\(tag).\(ext)"
        return alt
    }

    private func parentStemKey(parentID: UUID, stem: String) -> String {
        "\(parentID.uuidString)|*|\(normalizeStem(stem))"
    }

    /// Find Step-1 file for a Step-2 row (exact model, any model for that stem, or by name).
    private func resolveIntermediate(
        s2: AutomationStep2TrackPlan,
        map: [String: URL],
        outputs: [Step1StemOutput],
        dir: URL
    ) -> URL? {
        let fm = FileManager.default
        let exact = intermediateKey(parentID: s2.parentTrackID, modelID: s2.fromModelID, stem: s2.fromStem)
        if let u = map[exact], fm.fileExists(atPath: u.path) { return u }

        // Same parent + stem from any model (Add Step model id may drift after re-select).
        if let out = outputs.first(where: {
            $0.parentID == s2.parentTrackID && normalizeStem($0.stem) == normalizeStem(s2.fromStem)
                && fm.fileExists(atPath: $0.url.path)
        }) {
            return out.url
        }

        // By display name fragment in intermediate folder.
        let safe = AutomationNaming.sanitize(s2.displayName)
        if let files = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            if let match = files.first(where: {
                $0.pathExtension.lowercased() == "wav"
                    && $0.deletingPathExtension().lastPathComponent.contains(safe)
            }) {
                return match
            }
        }
        return nil
    }

    private func matchStemIndexed(_ wanted: String, in files: [StemFile], modelID: String = "", excluding: Set<Int>) -> (Int, StemFile)? {
        for (idx, file) in files.enumerated() where !excluding.contains(idx) {
            if let match = matchSingle(wanted, against: file, modelID: modelID) {
                return (idx, match)
            }
        }
        return nil
    }

    private func matchSingle(_ wanted: String, against file: StemFile, modelID: String) -> StemFile? {
        if isAnvuewKaraoke(modelID) {
            let w = baseStemID(wanted)
            if isLeadWanted(w) {
                let candidates = ["lead", "lead_vocal", "lead_vocals", "vocals", "vocal"]
                if candidates.contains(where: { baseStemID(file.stem) == $0 }) { return file }
                return nil
            }
            if isBackWanted(w) {
                let candidates = ["back", "back_vocal", "back_vocals", "backing", "instrumental", "instrument", "inst", "other"]
                if candidates.contains(where: { baseStemID(file.stem) == $0 }) { return file }
                return nil
            }
        }
        if file.stem.caseInsensitiveCompare(wanted) == .orderedSame { return file }
        let w = baseStemID(wanted)
        if baseStemID(file.stem) == w { return file }
        if stemAliasGroup(w) == stemAliasGroup(baseStemID(file.stem)) { return file }
        return nil
    }

    private func matchStem(_ wanted: String, in files: [StemFile], modelID: String = "") -> StemFile? {
        guard !files.isEmpty else { return nil }

        // Aura Lead / Back 2 (Anvuew): upstream YAML labels are inverted —
        // "Vocals" file = lead, "Instrumental" file = back.
        // Engine renames to lead/back; still accept raw labels for matching.
        if isAnvuewKaraoke(modelID) {
            let w = baseStemID(wanted)
            if isLeadWanted(w) {
                return firstStem(in: files, candidates: ["lead", "lead_vocal", "lead_vocals",
                                                         "vocals", "vocal"])
            }
            if isBackWanted(w) {
                return firstStem(in: files, candidates: ["back", "back_vocal", "back_vocals",
                                                         "backing", "instrumental", "instrument", "inst", "other"])
            }
        }

        if let exact = files.first(where: { $0.stem.caseInsensitiveCompare(wanted) == .orderedSame }) {
            return exact
        }

        let w = baseStemID(wanted)
        if let hit = files.first(where: { baseStemID($0.stem) == w }) {
            return hit
        }

        let wantedGroup = stemAliasGroup(w)
        if let hit = files.first(where: { stemAliasGroup(baseStemID($0.stem)) == wantedGroup }) {
            return hit
        }

        if wantedGroup == "vocals_lead", files.count == 2 {
            return files.first
        }
        if wantedGroup == "back_instrumental", files.count == 2 {
            return files.last
        }
        // Residual "other" only — never treat instrumental/inst as other (that stole files).
        if wantedGroup == "other" {
            if let hit = files.first(where: {
                let s = baseStemID($0.stem)
                return s == "other" || s == "rest" || s == "remainder"
            }) {
                return hit
            }
            if files.count == 2 {
                return files.last
            }
        }

        return nil
    }

    private func isAnvuewKaraoke(_ modelID: String) -> Bool {
        let id = modelID.lowercased()
        return id.contains("karaoke_anvuew")
            || id.contains("lead_back_karaoke")
            || id.contains("karaoke_bs_roformer_anvuew")
    }

    private func isLeadWanted(_ id: String) -> Bool {
        ["lead", "lead_vocal", "lead_vocals", "leadvocal"].contains(id)
    }

    private func isBackWanted(_ id: String) -> Bool {
        ["back", "back_vocal", "back_vocals", "backing", "backing_vocals", "bgv"].contains(id)
    }

    private func firstStem(in files: [StemFile], candidates: [String]) -> StemFile? {
        let set = Set(candidates.map { baseStemID($0) })
        return files.first { set.contains(baseStemID($0.stem)) }
    }

    private func baseStemID(_ s: String) -> String {
        var n = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        if let range = n.range(of: #"_+\d+$"#, options: .regularExpression) {
            n.removeSubrange(range)
        }
        return n
    }

    private func normalizeStem(_ s: String) -> String { baseStemID(s) }

    private func stemAliasGroup(_ id: String) -> String {
        switch id {
        case "lead", "lead_vocal", "lead_vocals", "leadvocal", "leadvocals",
             "vocals", "vocal":
            return "vocals_lead"
        case "back", "back_vocal", "back_vocals", "backing", "backing_vocal", "backing_vocals",
             "bgv", "bg_vocals",
             "instrumental", "instruments", "inst", "instrument", "karaoke", "no_vocals":
            return "back_instrumental"
        case "other", "rest", "remainder":
            return "other"
        case "drums", "drum":
            return "drums"
        case "no_drums", "nodrums", "no drums":
            return "no_drums"
        case "bass", "bass_guitar":
            return "bass"
        case "kick", "kick_drum", "bd":
            return "kick"
        case "snare", "snare_drum", "sd":
            return "snare"
        default:
            if id.contains("lead") || id.contains("vocal") { return "vocals_lead" }
            if id.contains("back") || id.contains("backing") || id.contains("instrument") {
                return "back_instrumental"
            }
            if id.contains("drum") { return "drums" }
            return id
        }
    }

    private func copyReplacing(from: URL, to: URL) throws {
        try linkOrCopy(from: from, to: to)
    }

    /// Prefer hardlink (bit-identical, zero re-encode). Fall back to copy across volumes.
    private func linkOrCopy(from: URL, to: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: to.path) {
            try fm.removeItem(at: to)
        }
        try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try fm.linkItem(at: from, to: to)
        } catch {
            try fm.copyItem(at: from, to: to)
        }
    }
}

enum AutomationRunnerError: LocalizedError {
    case validation(String)

    var errorDescription: String? {
        switch self {
        case .validation(let m): return m
        }
    }
}
