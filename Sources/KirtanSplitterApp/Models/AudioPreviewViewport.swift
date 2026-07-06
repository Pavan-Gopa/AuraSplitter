import Foundation

struct AudioPreviewViewport: Equatable {
    private static let minimumSpan = 0.01

    var start: Double = 0
    var end: Double = 1

    var span: Double {
        max(0.000_001, end - start)
    }

    var zoomFactor: Double {
        1 / span
    }

    var isZoomed: Bool {
        span < 0.999
    }

    mutating func reset() {
        start = 0
        end = 1
    }

    mutating func zoom(deltaY: Double, anchorFraction: Double) {
        guard deltaY != 0 else { return }
        let anchor = min(1, max(0, anchorFraction))
        let boundedSteps = min(8, max(1, abs(deltaY) / 10))
        let perStepFactor = 0.82
        let factor = deltaY > 0
            ? pow(perStepFactor, boundedSteps)
            : pow(1 / perStepFactor, boundedSteps)
        let nextSpan = min(1, max(Self.minimumSpan, span * factor))
        let anchorAbsolute = start + span * anchor
        let nextStart = anchorAbsolute - nextSpan * anchor
        apply(start: nextStart, span: nextSpan)
    }

    mutating func pan(deltaX: Double, canvasWidth: Double) {
        guard canvasWidth > 0, isZoomed else { return }
        let offset = -deltaX / canvasWidth * span
        apply(start: start + offset, span: span)
    }

    func absoluteFraction(forVisibleFraction visibleFraction: Double) -> Double {
        start + span * min(1, max(0, visibleFraction))
    }

    func visibleFraction(forAbsoluteFraction absoluteFraction: Double) -> Double? {
        guard absoluteFraction >= start, absoluteFraction <= end else { return nil }
        return (absoluteFraction - start) / span
    }

    private mutating func apply(start nextStart: Double, span nextSpan: Double) {
        if nextSpan >= 0.999 {
            reset()
            return
        }

        let clampedSpan = min(1, max(Self.minimumSpan, nextSpan))
        let clampedStart = min(max(0, nextStart), 1 - clampedSpan)
        start = clampedStart
        end = clampedStart + clampedSpan
    }
}
