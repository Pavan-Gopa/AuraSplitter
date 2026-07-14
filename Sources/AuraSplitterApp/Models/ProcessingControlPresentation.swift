import Foundation

struct ProcessingControlPresentation: Equatable {
    private enum State {
        case idle
        case running
        case cancelling
        case backendUnavailable
    }

    private let state: State

    init(isReady: Bool, isProcessing: Bool, isCancelling: Bool) {
        if isCancelling {
            state = .cancelling
        } else if isProcessing {
            state = .running
        } else if !isReady {
            state = .backendUnavailable
        } else {
            state = .idle
        }
    }

    var primaryTitle: String {
        switch state {
        case .idle: return "Start"
        case .running: return "Cancel"
        case .cancelling: return "Cancelling"
        case .backendUnavailable: return "Restart"
        }
    }

    var primarySystemImage: String {
        switch state {
        case .idle: return "play.fill"
        case .running: return "xmark.circle.fill"
        case .cancelling: return "xmark.circle"
        case .backendUnavailable: return "arrow.clockwise"
        }
    }

    var isDestructive: Bool {
        state == .running
    }

    var usesSeparateCancelButton: Bool {
        false
    }

    var isBusy: Bool {
        state == .running || state == .cancelling
    }

    func isPrimaryDisabled(hasSelectedSources: Bool) -> Bool {
        switch state {
        case .idle:
            return !hasSelectedSources
        case .running:
            return false
        case .cancelling:
            return true
        case .backendUnavailable:
            return false
        }
    }
}
