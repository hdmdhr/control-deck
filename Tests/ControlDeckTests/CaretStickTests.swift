import Foundation

@main struct CaretStickTests {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fatalError(message) }
    }

    static func main() {
        var engine = CaretStickEngine()
        require(engine.update(x: 1, y: 0, now: 0) == nil, "Startup must observe neutral before accepting a held stick")
        require(engine.update(x: 0.05, y: -0.06, now: 0) == nil, "Small neutral drift arms without moving")
        require(engine.update(x: 0.37, y: 0.30, now: 0.01) == nil, "Sub-threshold drift never starts repeating")
        require(engine.tick(now: 1) == nil, "Drift leaves no queued repeat")
        require(engine.update(x: 0.8, y: 0.2, now: 1) == .right, "First deliberate movement is immediate")
        require(engine.tick(now: 1.34) == nil, "Initial delay is respected")
        require(engine.tick(now: 1.35) == .right, "Initial repeat fires after 350 ms")
        require(engine.tick(now: 1.36) == nil, "A step is never duplicated by another timer tick")
        require(engine.tick(now: 1.441) == .right, "Held movement repeats every 90 ms")
        require(engine.update(x: 0.60, y: 0.65, now: 1.45) == nil, "Diagonal jitter keeps the existing axis")
        require(engine.update(x: 0.50, y: 0.80, now: 1.46) == .up, "A deliberate dominant-axis change steps immediately")
        require(engine.tick(now: 1.60) == nil, "Axis change restarts the initial delay")
        require(engine.update(x: 0.10, y: -0.80, now: 1.61) == .down, "Direct sign reversal changes direction without diagonal output")
        require(engine.update(x: 0.10, y: -0.28, now: 1.62) == nil, "Release hysteresis keeps an active direction above release threshold")
        require(engine.hasPendingRepeat, "Active deflection stays repeatable in the hysteresis band")
        require(engine.update(x: 0.21, y: -0.20, now: 1.63) == nil, "Returning to center stops immediately")
        require(!engine.hasPendingRepeat && engine.tick(now: 2) == nil, "Center cancels the pending repeat")
        require(engine.update(x: -0.8, y: 0, now: 2) == .left, "Next deliberate deflection starts immediately")
        engine.reset()
        require(engine.tick(now: 2.5) == nil, "Context reset clears all pending repeats")
        require(engine.update(x: -0.8, y: 0, now: 2.6) == nil, "A held stick cannot reactivate after a takeover")
        _ = engine.update(x: 0, y: 0, now: 2.7)
        require(engine.update(x: 0, y: 0.8, now: 2.8) == .up, "Neutral re-arms after a takeover")
        require(engine.tick(now: 20) == nil, "A long suspension never replays stale key steps")
        require(!engine.hasPendingRepeat && engine.requiresNeutral, "A long suspension requires fresh centering")
        require(engine.update(x: 0, y: 0.8, now: 20.1) == nil, "Stale held input remains suppressed")
        _ = engine.update(x: 0, y: 0, now: 21)
        require(engine.update(x: 1, y: 1, now: 21.1) == .right, "Initial diagonal emits exactly one dominant-axis key")
        require(engine.update(x: .nan, y: 0, now: 21.2) == nil && !engine.hasPendingRepeat, "Invalid samples cancel safely")
        print("PASS: caret stick direction, drift, hysteresis, repeat and lifecycle reset")
    }
}
