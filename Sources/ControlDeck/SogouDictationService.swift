import AppKit
import ApplicationServices

/// Mirror the user's configured hold-right-Option shortcut. Sogou owns its
/// activation threshold, recording and insertion; we do not infer ASR success.
@MainActor
final class SogouDictationService {
    private(set) var isActive = false
    var onPressed: (() -> Void)?
    var onReleased: (() -> Void)?
    private let press: @MainActor () -> Bool
    private let release: @MainActor () -> Void
    static let bundleID = "com.sogou.voiceassistant"

    init(press: @escaping @MainActor () -> Bool = { RightOptionShortcut.shared.press() },
         release: @escaping @MainActor () -> Void = { RightOptionShortcut.shared.release() }) {
        self.press = press
        self.release = release
    }

    func begin() -> Bool {
        guard !isActive, press() else { return false }
        isActive = true
        onPressed?()
        return true
    }

    func stop() {
        guard isActive else { return }
        // Mark idle before callbacks so repeated releases cannot post twice.
        isActive = false
        release()
        onReleased?()
    }

    func stopBeforeExit() { stop() }
}

/// A modifier key uses flagsChanged, including the device-specific right-side
/// bit. Reserve its key-up before posting down so cleanup cannot fail to allocate.
@MainActor
final class RightOptionShortcut {
    static let shared = RightOptionShortcut()
    static let rightOption: CGKeyCode = 61
    static let leftOption: CGKeyCode = 58
    static let rightOptionFlag = CGEventFlags(rawValue: 0x40) // NX_DEVICERALTKEYMASK
    private var pendingRelease: CGEvent?

    func press() -> Bool {
        let modifiers: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn]
        let currentFlags = CGEventSource.flagsState(.combinedSessionState)
        guard pendingRelease == nil, AXIsProcessTrusted(),
              currentFlags.intersection(modifiers).isEmpty,
              !CGEventSource.keyState(.hidSystemState, key: Self.rightOption),
              let source = CGEventSource(stateID: .privateState),
              let down = Self.event(source: source, pressed: true, currentFlags: currentFlags),
              let up = Self.event(source: source, pressed: false) else { return false }
        pendingRelease = up
        down.post(tap: .cghidEventTap)
        return true
    }

    func release() {
        guard let up = pendingRelease else { return }
        pendingRelease = nil
        // Preserve other modifiers the user pressed during dictation, including
        // a physical left Option. Remove only our right-side Option state.
        Self.prepareRelease(up, current: CGEventSource.flagsState(.combinedSessionState),
            leftOptionHeld: CGEventSource.keyState(.hidSystemState, key: Self.leftOption),
            timestamp: DispatchTime.now().uptimeNanoseconds)
        up.post(tap: .cghidEventTap)
    }

    static func prepareRelease(_ event: CGEvent, current: CGEventFlags,
                               leftOptionHeld: Bool, timestamp: CGEventTimestamp) {
        // This event was allocated before the hold. Its timestamp must reflect
        // release time, otherwise a long-press listener could see a zero-length tap.
        event.timestamp = timestamp
        event.flags = releaseFlags(current: current, leftOptionHeld: leftOptionHeld)
    }

    static func releaseFlags(current: CGEventFlags, leftOptionHeld: Bool) -> CGEventFlags {
        var flags = current.subtracting(rightOptionFlag)
        if leftOptionHeld { flags.insert(.maskAlternate) }
        else { flags.remove(.maskAlternate) }
        return flags
    }

    static func event(source: CGEventSource, pressed: Bool, currentFlags: CGEventFlags = []) -> CGEvent? {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: rightOption, keyDown: pressed) else { return nil }
        event.type = .flagsChanged
        event.flags = pressed ? currentFlags.union([.maskAlternate, rightOptionFlag]) : []
        return event
    }
}
