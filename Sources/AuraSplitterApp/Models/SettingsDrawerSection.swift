import Foundation

enum SettingsDrawerSection: String, CaseIterable, Identifiable {
    case process
    case models
    case run
    case logs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .process: return "Process"
        case .models: return "Models"
        case .run: return "Last Run"
        case .logs: return "Logs"
        }
    }

    var systemImage: String {
        switch self {
        case .process: return "slider.horizontal.3"
        case .models: return "externaldrive"
        case .run: return "timer"
        case .logs: return "doc.text.magnifyingglass"
        }
    }
}
