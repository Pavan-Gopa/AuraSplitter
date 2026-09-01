import XCTest
import Combine
@testable import AuraSplitterApp

@MainActor
final class AutomationMatrixTests: XCTestCase {
    private let auraProID = "kirtan_pro"
    private let auraVocalProID = "hyperace_v2_vocal"
    private let auraBackVocalID = "mega_back_vocal"

    private func configureCatalog(on store: AutomationWizardStore) {
        store.configureMatrixPresets([
            SeparationPreset(
                id: auraProID,
                title: "Aura Pro",
                modelFilename: "aura-pro.ckpt",
                summary: "Six stem test preset",
                expectedStems: ["vocals", "drums", "bass", "guitar", "piano", "other"]
            ),
            SeparationPreset(
                id: auraVocalProID,
                title: "Aura Vocal Pro",
                modelFilename: "aura-vocal-pro.ckpt",
                summary: "Two stem test preset",
                expectedStems: ["vocals", "instrument"]
            ),
            SeparationPreset(
                id: auraBackVocalID,
                title: "Aura Back Vocal",
                modelFilename: "aura-back-vocal.ckpt",
                summary: "Two stem test preset",
                expectedStems: ["back-vocal", "other"]
            )
        ])
    }
    func testReportedAuraProDrumToggleIsScopedAndStepTwoNamesPersist() {
        let firstTrackID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondTrackID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let firstTrack = AutomationTrackPlan(
            id: firstTrackID,
            sourceURL: URL(fileURLWithPath: "/tmp/main.wav"),
            shortOutputName: "Main Vocal"
        )
        let secondTrack = AutomationTrackPlan(
            id: secondTrackID,
            sourceURL: URL(fileURLWithPath: "/tmp/backup.wav"),
            shortOutputName: "Backup"
        )
        let store = AutomationWizardStore()
        configureCatalog(on: store)
        store.job.sourceFolderPath = "/tmp"
        store.job.outputFolderPath = "/tmp/Ready MIX"
        store.job.tracks = [firstTrack, secondTrack]

        // Reproduce the report: click Aura Pro's red second icon (drums).
        store.toggleStem(trackID: firstTrackID, modelID: auraProID, stem: "drums")

        let selected = store.job.tracks
            .flatMap { track in
                track.stemSelections.flatMap { modelID, stems in
                    stems.map { (trackID: track.id, modelID: modelID, stem: $0) }
                }
            }
        XCTAssertEqual(selected.count, 1)
        XCTAssertEqual(selected.first?.trackID, firstTrackID)
        XCTAssertEqual(selected.first?.modelID, auraProID)
        XCTAssertEqual(selected.first?.stem, "drums")
        XCTAssertTrue(store.isStemSelected(trackID: firstTrackID, modelID: auraProID, stem: "drums"))
        XCTAssertFalse(store.isStemSelected(trackID: firstTrackID, modelID: auraVocalProID, stem: "instrument"))
        XCTAssertFalse(store.isStemSelected(trackID: firstTrackID, modelID: auraBackVocalID, stem: "other"))
        XCTAssertFalse(store.isStemSelected(trackID: secondTrackID, modelID: auraProID, stem: "drums"))

        // Every Aura Pro slot must be independently toggleable, including the
        // three roles that were reported as dead.
        let auraProStems = ["vocals", "drums", "bass", "guitar", "piano", "other"]
        for stem in auraProStems where stem != "drums" {
            store.toggleStem(trackID: firstTrackID, modelID: auraProID, stem: stem)
        }
        XCTAssertEqual(store.job.tracks[0].stemSelections[auraProID], Set(auraProStems))
        // Unsupported roles are not valid cells for this preset.
        store.toggleStem(trackID: firstTrackID, modelID: auraProID, stem: "instrument")
        XCTAssertFalse(store.isStemSelected(trackID: firstTrackID, modelID: auraProID, stem: "instrument"))
        XCTAssertEqual(store.job.tracks[0].stemSelections[auraProID], Set(auraProStems))

        // Final names are edited before step 2 is created and must feed its
        // intermediate rows.
        store.setShortName(for: firstTrackID, name: "Lead Mix")
        store.setShortName(for: secondTrackID, name: "Backup Mix")
        XCTAssertEqual(store.job.tracks.first?.shortOutputName, "Lead Mix")
        XCTAssertEqual(store.job.tracks.last?.shortOutputName, "Backup Mix")

        store.addMatrixStep()
        XCTAssertNil(store.stepError)
        XCTAssertEqual(store.job.step2Tracks.count, auraProStems.count)
        XCTAssertEqual(Set(store.job.step2Tracks.map(\.fromStem)), Set(auraProStems))
        XCTAssertEqual(Set(store.job.step2Tracks.map(\.fromModelID)), [auraProID])
        XCTAssertEqual(Set(store.job.step2Tracks.map(\.parentTrackID)), [firstTrackID])
        XCTAssertTrue(store.job.step2Tracks.allSatisfy { $0.shortOutputName.hasPrefix("Lead Mix(") })

        let firstStep2ID = try! XCTUnwrap(store.job.step2Tracks.first?.id)
        store.setStep2ShortName(for: firstStep2ID, name: "Lead Vocal Final")
        XCTAssertEqual(store.job.step2Tracks.first?.shortOutputName, "Lead Vocal Final")
    }

    func testReportedCrossColumnSequenceRemainsModelScoped() {
        let trackID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let track = AutomationTrackPlan(
            id: trackID,
            sourceURL: URL(fileURLWithPath: "/tmp/song.wav"),
            shortOutputName: "Song"
        )
        let store = AutomationWizardStore()
        configureCatalog(on: store)
        store.job.outputFolderPath = "/tmp/Ready MIX"
        store.job.tracks = [track]
        // These are the neighboring clicks described by the report. The store
        // must keep each click in its own (track, model, stem) cell.
        store.toggleStem(trackID: trackID, modelID: auraProID, stem: "drums")
        store.toggleStem(trackID: trackID, modelID: auraVocalProID, stem: "instrument")
        store.toggleStem(trackID: trackID, modelID: auraBackVocalID, stem: "other")

        XCTAssertEqual(store.job.tracks[0].stemSelections, [
            auraProID: ["drums"],
            auraVocalProID: ["instrument"],
            auraBackVocalID: ["other"]
        ])
        XCTAssertEqual(store.job.tracks[0].selectedStemCount, 3)
    }
    func testCatalogFiltersUnsupportedStoredRolesBeforeBuildingStepTwo() {
        let trackID = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
        let track = AutomationTrackPlan(
            id: trackID,
            sourceURL: URL(fileURLWithPath: "/tmp/filter.wav"),
            shortOutputName: "Filter",
            stemSelections: [
                auraProID: ["drums", "instrument"],
                auraVocalProID: ["instrument", "drums"],
                "stale-model": ["vocals"]
            ]
        )
        let store = AutomationWizardStore()
        store.job.outputFolderPath = "/tmp/Ready MIX"
        store.job.tracks = [track]

        configureCatalog(on: store)

        XCTAssertEqual(store.job.tracks[0].stemSelections, [
            auraProID: ["drums"],
            auraVocalProID: ["instrument"]
        ])

        store.addMatrixStep()

        XCTAssertNil(store.stepError)
        XCTAssertEqual(
            Set(store.job.step2Tracks.map { ($0.fromModelID, $0.fromStem) }.map { "\($0.0):\($0.1)" }),
            ["\(auraProID):drums", "\(auraVocalProID):instrument"]
        )
    }

    func testFinalNameMutationsPublishForSwiftUIBindings() {
        let trackID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        let track = AutomationTrackPlan(
            id: trackID,
            sourceURL: URL(fileURLWithPath: "/tmp/name.wav"),
            shortOutputName: "Original"
        )
        let store = AutomationWizardStore()
        store.job.tracks = [track]

        var emissions = 0
        let subscription = store.objectWillChange.sink { _ in emissions += 1 }
        store.setShortName(for: trackID, name: "Edited")

        XCTAssertEqual(store.job.tracks.first?.shortOutputName, "Edited")
        XCTAssertGreaterThan(emissions, 0)
        withExtendedLifetime(subscription) {}
    }

    func testDeselectionPrunesStepTwoSourcesAndPublishesNestedMutation() {
        let trackID = UUID(uuidString: "00000000-0000-0000-0000-000000000006")!
        let track = AutomationTrackPlan(
            id: trackID,
            sourceURL: URL(fileURLWithPath: "/tmp/prune.wav"),
            shortOutputName: "Prune",
            stemSelections: [auraProID: ["vocals"]]
        )
        let store = AutomationWizardStore()
        configureCatalog(on: store)
        store.job.outputFolderPath = "/tmp/Ready MIX"
        store.job.tracks = [track]
        store.addMatrixStep()
        XCTAssertNil(store.stepError)
        XCTAssertEqual(store.job.step2Tracks.count, 1)
        XCTAssertEqual(store.job.matrixPipelineStep, 2)

        var emissions = 0
        let subscription = store.objectWillChange.sink { _ in emissions += 1 }
        store.toggleTrackSelection(trackID)

        XCTAssertFalse(store.job.tracks[0].isSelected)
        XCTAssertTrue(store.job.step2Tracks.isEmpty)
        XCTAssertEqual(store.job.matrixPipelineStep, 1)
        XCTAssertGreaterThan(emissions, 0)
        withExtendedLifetime(subscription) {}
    }

    func testEmptyCatalogDropsSelectionsAndKeepsValidationVisible() {
        let trackID = UUID(uuidString: "00000000-0000-0000-0000-000000000007")!
        let track = AutomationTrackPlan(
            id: trackID,
            sourceURL: URL(fileURLWithPath: "/tmp/empty-catalog.wav"),
            shortOutputName: "Empty Catalog",
            stemSelections: [auraProID: ["vocals"]]
        )
        let store = AutomationWizardStore()
        store.job.outputFolderPath = "/tmp/Ready MIX"
        store.job.tracks = [track]

        store.configureMatrixPresets([])
        XCTAssertTrue(store.job.tracks[0].stemSelections.isEmpty)
        store.addMatrixStep()

        XCTAssertEqual(
            store.stepError,
            "Select stems in Step 1 — they become Step 2 sources."
        )
        XCTAssertTrue(store.job.step2Tracks.isEmpty)
        XCTAssertEqual(store.job.matrixPipelineStep, 1)
    }

    func testStepTwoStemToggleIsRoleScopedAndUnsupportedRolesAreIgnored() {
        let trackID = UUID(uuidString: "00000000-0000-0000-0000-000000000008")!
        let track = AutomationTrackPlan(
            id: trackID,
            sourceURL: URL(fileURLWithPath: "/tmp/step-two.wav"),
            shortOutputName: "Step Two",
            stemSelections: [auraProID: ["vocals"]]
        )
        let store = AutomationWizardStore()
        configureCatalog(on: store)
        store.job.outputFolderPath = "/tmp/Ready MIX"
        store.job.tracks = [track]
        store.addMatrixStep()
        let rowID = try! XCTUnwrap(store.job.step2Tracks.first?.id)

        store.toggleStep2Stem(trackID: rowID, modelID: auraVocalProID, stem: "instrument")
        XCTAssertTrue(store.isStep2StemSelected(
            trackID: rowID,
            modelID: auraVocalProID,
            stem: "instrument"
        ))
        store.toggleStep2Stem(trackID: rowID, modelID: auraVocalProID, stem: "drums")
        XCTAssertFalse(store.isStep2StemSelected(
            trackID: rowID,
            modelID: auraVocalProID,
            stem: "drums"
        ))
        XCTAssertEqual(
            store.job.step2Tracks.first?.stemSelections,
            [auraVocalProID: ["instrument"]]
        )
    }
    func testStepTwoReconciliationPreservesIdentityNamesSelectionAndModelScopedStems() {
        let trackID = UUID(uuidString: "00000000-0000-0000-0000-000000000009")!
        let track = AutomationTrackPlan(
            id: trackID,
            sourceURL: URL(fileURLWithPath: "/tmp/reconcile.wav"),
            shortOutputName: "Reconcile",
            stemSelections: [
                auraProID: ["vocals"],
                auraVocalProID: ["instrument"]
            ]
        )
        let store = AutomationWizardStore()
        configureCatalog(on: store)
        store.job.outputFolderPath = "/tmp/Ready MIX"
        store.job.tracks = [track]
        store.addMatrixStep()
        XCTAssertNil(store.stepError)
        XCTAssertEqual(store.job.step2Tracks.count, 2)

        let vocalID = try! XCTUnwrap(
            store.job.step2Tracks.first {
                $0.fromModelID == auraProID && $0.fromStem == "vocals"
            }?.id
        )
        let instrumentID = try! XCTUnwrap(
            store.job.step2Tracks.first {
                $0.fromModelID == auraVocalProID && $0.fromStem == "instrument"
            }?.id
        )
        store.setStep2ShortName(for: vocalID, name: "Custom Vocal Final")
        store.toggleStep2TrackSelection(instrumentID)
        store.toggleStep2Stem(
            trackID: vocalID,
            modelID: auraVocalProID,
            stem: "instrument"
        )

        // Inject a stale role so the next reconciliation must prune it while
        // retaining the valid model-scoped role above.
        var rows = store.job.step2Tracks
        let vocalIndex = rows.firstIndex { $0.id == vocalID }!
        rows[vocalIndex].stemSelections = [
            auraProID: ["instrument"],
            auraVocalProID: ["instrument"]
        ]
        store.job.step2Tracks = rows

        // A new Step-1 source must be added without rebuilding surviving rows.
        store.toggleStem(trackID: trackID, modelID: auraProID, stem: "drums")
        XCTAssertEqual(store.job.step2Tracks.count, 3)

        let preservedBeforeRebuild = try! XCTUnwrap(
            store.job.step2Tracks.first { $0.id == vocalID }
        )
        XCTAssertEqual(preservedBeforeRebuild.shortOutputName, "Custom Vocal Final")
        XCTAssertEqual(preservedBeforeRebuild.stemSelections, [
            auraVocalProID: ["instrument"]
        ])
        XCTAssertTrue(preservedBeforeRebuild.isSelected)

        let deselectedBeforeRebuild = try! XCTUnwrap(
            store.job.step2Tracks.first { $0.id == instrumentID }
        )
        XCTAssertFalse(deselectedBeforeRebuild.isSelected)

        // Rebuilding the matrix must keep semantic survivors by UUID and
        // retain their editable state.
        store.addMatrixStep()
        let preservedAfterRebuild = try! XCTUnwrap(
            store.job.step2Tracks.first { $0.id == vocalID }
        )
        XCTAssertEqual(preservedAfterRebuild.shortOutputName, "Custom Vocal Final")
        XCTAssertEqual(preservedAfterRebuild.stemSelections, [
            auraVocalProID: ["instrument"]
        ])
        XCTAssertTrue(preservedAfterRebuild.isSelected)

        let deselectedAfterRebuild = try! XCTUnwrap(
            store.job.step2Tracks.first { $0.id == instrumentID }
        )
        XCTAssertFalse(deselectedAfterRebuild.isSelected)
        XCTAssertTrue(
            store.job.step2Tracks.contains {
                $0.fromModelID == auraProID && $0.fromStem == "drums"
            }
        )
    }

}
