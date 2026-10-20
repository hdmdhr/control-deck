import AppKit

@main struct SogouDictationTests {
    @MainActor static func main() {
        func check(_ condition: Bool, _ message: String) { precondition(condition, message) }
        var events: [String] = []
        var allowed = true
        let service = SogouDictationService(press: {
            guard allowed else { return false }
            events.append("down")
            return true
        }, release: { events.append("up") })
        service.onPressed = { events.append("pressed") }
        service.onReleased = { events.append("released") }
        check(service.begin(), "Hold starts immediately without launching or polling another app")
        check(!service.begin(), "Repeated keydown cannot send another Option down")
        service.stop(); service.stop()
        check(events == ["down", "pressed", "up", "released"] && !service.isActive,
              "Exactly one paired release, including a quick tap")

        events = []; allowed = false
        check(!service.begin(), "Denied press does not claim an active shortcut")
        service.stop(); service.stopBeforeExit()
        check(events.isEmpty && !service.isActive, "Denied press never releases a key it did not own")

        events = []; allowed = true
        check(service.begin(), "Another hold accepted after release")
        service.stopBeforeExit(); service.stop()
        check(events == ["down", "pressed", "up", "released"], "Shutdown synchronously releases once")

        let source = CGEventSource(stateID: .privateState)!
        let down = RightOptionShortcut.event(source: source, pressed: true)!
        let up = RightOptionShortcut.event(source: source, pressed: false)!
        check(down.type == .flagsChanged && up.type == .flagsChanged, "Modifier uses flagsChanged events")
        check(down.getIntegerValueField(.keyboardEventKeycode) == 61 && up.getIntegerValueField(.keyboardEventKeycode) == 61,
              "Both events identify right Option rather than left Option")
        check(down.flags.contains(.maskAlternate) && down.flags.contains(RightOptionShortcut.rightOptionFlag),
              "Key down includes the right-side Option bit required by side-specific shortcuts")
        check(!up.flags.contains(.maskAlternate) && !up.flags.contains(RightOptionShortcut.rightOptionFlag),
              "Key up clears Option")
        let held: CGEventFlags = [.maskAlternate, .maskShift, .maskCommand, RightOptionShortcut.rightOptionFlag]
        let released = RightOptionShortcut.releaseFlags(current: held, leftOptionHeld: false)
        check(released == [.maskShift, .maskCommand], "Cleanup preserves unrelated physical modifiers")
        let leftHeld = RightOptionShortcut.releaseFlags(current: held, leftOptionHeld: true)
        check(leftHeld.contains(.maskAlternate) && !leftHeld.contains(RightOptionShortcut.rightOptionFlag),
              "Cleanup preserves the user's physical left Option")
        up.timestamp = 1
        RightOptionShortcut.prepareRelease(up, current: held, leftOptionHeld: false, timestamp: 5_000_000_001)
        check(up.timestamp == 5_000_000_001 && up.flags == [.maskShift, .maskCommand],
              "Reserved key-up gets its actual release time so a long hold is not mistaken for a tap")
        print("PASS: Sogou right-Option hold/release, denied press, shutdown and modifier identity")
    }
}
