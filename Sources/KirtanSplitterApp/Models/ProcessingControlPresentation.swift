import Foundation

struct ProcessingControlPresentation: Equatable {
    private enum State {
        case idle
        case running
        case cancelling
    }

    private let state: State

    init(isProcessing: Bool, isCancelling: Bool) {
        if isCancelling {
            state = .cancelling
        } else if isProcessing {
            state = .running
        } else {
            state = .idle
        }
    }

    var primaryTitle: String {
        switch state {
        case .idle: return "Start"
        case .running: return "Separating"
        case .cancelling: return "Cancelling"
        }
    }

    var primarySystemImage: String {
        switch state {
        case .idle: return "play.fill"
        case .running: return "hourglass"
        case .cancelling: return "xmark.circle"
        }
    }

    var showsCancelAction: Bool {
        state == .running
    }

    var isBusy: Bool {
        state != .idle
    }

    func isStartDisabled(isReady: Bool, hasSelectedSources: Bool) -> Bool {
        !isReady || !hasSelectedSources || isBusy
    }
}
