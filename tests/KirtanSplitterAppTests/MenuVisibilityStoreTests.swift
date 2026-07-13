import XCTest
@testable import KirtanSplitterApp

final class MenuVisibilityStoreTests: XCTestCase {
    private func makeStore() -> (MenuVisibilityStore, UserDefaults, String) {
        let suite = "MenuVisibilityStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (MenuVisibilityStore(defaults: defaults), defaults, suite)
    }

    // MARK: - Default = all visible

    func testDefaultHidesNothing() {
        let (store, _, _) = makeStore()
        XCTAssertTrue(store.isModelVisible("kirtan_pro"))
        XCTAssertTrue(store.isModelVisible("anything"))
        XCTAssertTrue(store.isProcessPresetVisible("builtin.heavy"))
        XCTAssertTrue(store.isProcessPresetVisible("custom.abc"))
        XCTAssertTrue(store.hiddenModelIDs.isEmpty)
        XCTAssertTrue(store.hiddenProcessPresetIDs.isEmpty)
    }

    // MARK: - Toggle / filter

    func testHidingModelThenProcessPreset() {
        let (store, _, _) = makeStore()

        store.toggleModelVisibility("kirtan_pro")
        XCTAssertFalse(store.isModelVisible("kirtan_pro"))
        XCTAssertTrue(store.isModelVisible("kirtan_vocal"))

        store.toggleProcessPresetVisibility("builtin.heavy")
        XCTAssertFalse(store.isProcessPresetVisible("builtin.heavy"))
        XCTAssertTrue(store.isProcessPresetVisible("builtin.default"))

        // Re-enable
        store.toggleModelVisibility("kirtan_pro")
        store.toggleProcessPresetVisibility("builtin.heavy")
        XCTAssertTrue(store.isModelVisible("kirtan_pro"))
        XCTAssertTrue(store.isProcessPresetVisible("builtin.heavy"))
        XCTAssertTrue(store.hiddenModelIDs.isEmpty)
        XCTAssertTrue(store.hiddenProcessPresetIDs.isEmpty)
    }

    func testSetVisibleExplicitly() {
        let (store, _, _) = makeStore()
        store.setModelVisible(false, for: "kirtan_pro")
        store.setProcessPresetVisible(false, for: "builtin.fast")
        XCTAssertFalse(store.isModelVisible("kirtan_pro"))
        XCTAssertFalse(store.isProcessPresetVisible("builtin.fast"))

        store.setModelVisible(true, for: "kirtan_pro")
        store.setProcessPresetVisible(true, for: "builtin.fast")
        XCTAssertTrue(store.isModelVisible("kirtan_pro"))
        XCTAssertTrue(store.isProcessPresetVisible("builtin.fast"))
    }

    // MARK: - Persistence

    func testVisibilityPersistsAcrossInstances() {
        let (store, defaults, suite) = makeStore()
        store.toggleModelVisibility("kirtan_pro")
        store.toggleProcessPresetVisibility("builtin.heavy")

        let reloaded = MenuVisibilityStore(defaults: defaults)
        XCTAssertFalse(reloaded.isModelVisible("kirtan_pro"))
        XCTAssertFalse(reloaded.isProcessPresetVisible("builtin.heavy"))
        XCTAssertTrue(reloaded.isModelVisible("kirtan_vocal"))

        // Clean up
        defaults.removePersistentDomain(forName: suite)
    }

    // MARK: - Preferred visible model

    func testPreferredVisibleModelSkipsHiddenAndUsesCatalogOrder() {
        let (store, _, _) = makeStore()
        let presets = [
            SeparationPreset(id: "kirtan_pro", title: "Aura Pro", modelFilename: "a.ckpt", summary: "", expectedStems: []),
            SeparationPreset(id: "vocal_clean", title: "Aura Clean", modelFilename: "b.ckpt", summary: "", expectedStems: []),
            SeparationPreset(id: "leap_xe_vocal", title: "Aura Vocal Elite", modelFilename: "c.ckpt", summary: "", expectedStems: []),
        ]

        XCTAssertEqual(store.preferredVisibleModelID(in: presets), "kirtan_pro")

        store.setModelVisible(false, for: "kirtan_pro")
        XCTAssertEqual(store.preferredVisibleModelID(in: presets), "vocal_clean")
        XCTAssertEqual(
            store.preferredVisibleModelID(in: presets, excluding: "kirtan_pro"),
            "vocal_clean"
        )

        store.setModelVisible(false, for: "vocal_clean")
        XCTAssertEqual(store.preferredVisibleModelID(in: presets), "leap_xe_vocal")
    }
}
