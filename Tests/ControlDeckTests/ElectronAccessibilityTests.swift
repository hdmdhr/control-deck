import Foundation

@main struct ElectronAccessibilityTests {
    @MainActor static func main() async {
        func require(_ value: Bool, _ message: String) {
            precondition(value, message)
        }
        var reads = 0
        var waits = 0
        let ready: Int? = await ElectronAccessibility.waitForSnapshot(isFocused: { true }, read: {
            reads += 1
            return reads == 3 ? 42 : nil
        }, pause: { waits += 1 })
        require(ready == 42 && reads == 3 && waits == 2, "Wait for the asynchronously populated renderer tree")

        reads = 0
        let chromium: Int? = await ElectronAccessibility.waitForSnapshot(attempts: 35, isFocused: { true }, read: {
            reads += 1
            return reads == 23 ? 42 : nil
        }, pause: {})
        require(chromium == 42 && reads == 23, "Chromium's two-second enhanced-UI debounce fits the startup wait")

        reads = 0
        waits = 0
        let absent: Int? = await ElectronAccessibility.waitForSnapshot(isFocused: { true }, read: {
            reads += 1
            return nil
        }, pause: { waits += 1 })
        require(absent == nil && reads == 8 && waits == 7, "Missing sidebar stops after a bounded wait")

        reads = 0
        var focused = true
        let changed: Int? = await ElectronAccessibility.waitForSnapshot(isFocused: { focused }, read: {
            reads += 1
            return nil
        }, pause: { focused = false })
        require(changed == nil && reads == 1, "Focus changes during tree initialization prevent further reads")

        focused = true
        let stale: Int? = await ElectronAccessibility.waitForSnapshot(isFocused: { focused }, read: {
            focused = false
            return 42
        }, pause: {})
        require(stale == nil, "Reject a snapshot if focus changed during the read")

        enum Cancelled: Error { case interrupted }
        reads = 0
        let interrupted: Int? = await ElectronAccessibility.waitForSnapshot(isFocused: { true }, read: {
            reads += 1
            return nil
        }, pause: { throw Cancelled.interrupted })
        require(interrupted == nil && reads == 1, "Interrupted waits never proceed to navigation")

        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await ElectronAccessibility.waitForSnapshot(isFocused: { true }, read: { 42 }, pause: {})
        }
        let cancelled = await task.value
        require(cancelled == nil, "Cancelled navigation cannot consume a ready snapshot")
        print("PASS: Electron renderer readiness, bounded retry, focus and cancellation")
    }
}
