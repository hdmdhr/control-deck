import Foundation

/// Discrete, unmodified arrow steps. Timing is supplied by the caller so this
/// state machine never depends on wall-clock changes or the system keyboard.
struct CaretStickEngine {
    enum Direction: Equatable {
        case left, right, up, down
    }

    static let enterThreshold: Float = 0.38
    static let releaseThreshold: Float = 0.22
    static let axisSwitchMargin: Float = 0.16
    static let initialDelay: TimeInterval = 0.35
    static let repeatInterval: TimeInterval = 0.09

    private(set) var direction: Direction?
    private(set) var requiresNeutral = true
    private var repeatDeadline: TimeInterval?

    var hasPendingRepeat: Bool { direction != nil }

    mutating func reset() {
        direction = nil
        repeatDeadline = nil
        requiresNeutral = true
    }

    /// Returning a value represents exactly one key-down/key-up pair.
    mutating func update(x: Float, y: Float, now: TimeInterval) -> Direction? {
        guard x.isFinite, y.isFinite, now.isFinite else {
            reset()
            return nil
        }
        let horizontal = abs(x)
        let vertical = abs(y)
        if max(horizontal, vertical) <= Self.releaseThreshold {
            direction = nil
            repeatDeadline = nil
            requiresNeutral = false
            return nil
        }
        guard !requiresNeutral else { return nil }

        let candidate: Direction
        if let direction {
            let isHorizontal = direction == .left || direction == .right
            let currentMagnitude = isHorizontal ? horizontal : vertical
            let otherMagnitude = isHorizontal ? vertical : horizontal
            let switchAxis = otherMagnitude >= Self.enterThreshold &&
                (currentMagnitude <= Self.releaseThreshold ||
                 otherMagnitude >= currentMagnitude + Self.axisSwitchMargin)
            if switchAxis {
                candidate = isHorizontal ? (y > 0 ? .up : .down) : (x > 0 ? .right : .left)
            } else if currentMagnitude > Self.releaseThreshold {
                candidate = isHorizontal ? (x > 0 ? .right : .left) : (y > 0 ? .up : .down)
                // A sign reversal needs a deliberate deflection too.
                if candidate != direction && currentMagnitude < Self.enterThreshold {
                    self.direction = nil
                    repeatDeadline = nil
                    return nil
                }
            } else {
                self.direction = nil
                repeatDeadline = nil
                return nil
            }
        } else {
            guard max(horizontal, vertical) >= Self.enterThreshold else { return nil }
            candidate = horizontal >= vertical ? (x > 0 ? .right : .left) : (y > 0 ? .up : .down)
        }
        guard candidate != direction else { return nil }
        direction = candidate
        repeatDeadline = now + Self.initialDelay
        return candidate
    }

    mutating func tick(now: TimeInterval) -> Direction? {
        guard let direction, let repeatDeadline, now >= repeatDeadline else { return nil }
        // Sleep, modal stalls and debugger pauses must not replay old input.
        guard now - repeatDeadline <= 0.30 else {
            reset()
            return nil
        }
        self.repeatDeadline = now + Self.repeatInterval
        return direction
    }
}
