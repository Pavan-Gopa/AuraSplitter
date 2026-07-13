import Foundation

/// Persistent eye-visibility for the compact header dropdowns.
///
/// Design: an *empty* hidden set means "no restrictions" -> everything is
/// visible (the default). Toggling an eye OFF adds the id to the hidden set;
/// toggling it ON removes it. Only the toggled-off items are hidden from the
/// header shortlists; selections are never cleared. The full lists always
/// remain visible (with their eye toggles) in Settings.
final class MenuVisibilityStore: ObservableObject {
    static let shared = MenuVisibilityStore()

    @Published private(set) var hiddenModelIDs: Set<String>
    @Published private(set) var hiddenProcessPresetIDs: Set<String>

    private let defaults: UserDefaults
    private let modelKey = "KirtanSplitter.hiddenModelIDs"
    private let processKey = "KirtanSplitter.hiddenProcessPresetIDs"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let modelRaw = defaults.array(forKey: modelKey) as? [String] ?? []
        let processRaw = defaults.array(forKey: processKey) as? [String] ?? []
        hiddenModelIDs = Set(modelRaw)
        hiddenProcessPresetIDs = Set(processRaw)
    }

    // MARK: Models (preset IDs used by the model picker, e.g. kirtan_pro)

    func isModelVisible(_ id: String) -> Bool {
        !hiddenModelIDs.contains(id)
    }

    func setModelVisible(_ visible: Bool, for id: String) {
        if visible {
            hiddenModelIDs.remove(id)
        } else {
            hiddenModelIDs.insert(id)
        }
        persist()
    }

    func toggleModelVisibility(_ id: String) {
        setModelVisible(!isModelVisible(id), for: id)
    }

    // MARK: Process presets (built-in + custom ids, e.g. builtin.heavy)

    func isProcessPresetVisible(_ id: String) -> Bool {
        !hiddenProcessPresetIDs.contains(id)
    }

    func setProcessPresetVisible(_ visible: Bool, for id: String) {
        if visible {
            hiddenProcessPresetIDs.remove(id)
        } else {
            hiddenProcessPresetIDs.insert(id)
        }
        persist()
    }

    func toggleProcessPresetVisibility(_ id: String) {
        setProcessPresetVisible(!isProcessPresetVisible(id), for: id)
    }

    private func persist() {
        defaults.set(Array(hiddenModelIDs), forKey: modelKey)
        defaults.set(Array(hiddenProcessPresetIDs), forKey: processKey)
    }
}
