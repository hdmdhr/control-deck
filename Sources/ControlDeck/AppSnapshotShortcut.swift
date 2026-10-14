import AppKit
import Carbon

/// Modifier-only shortcuts require flagsChanged events and side-specific flags.
/// These masks are NX_DEVICELCMDKEYMASK/NX_DEVICERCMDKEYMASK in IOLLEvent.h.
enum AppSnapshotShortcut {
    static func events() -> [CGEvent]? {
        let command = CGEventFlags.maskCommand.rawValue
        let states: [(Int, UInt64)] = [
            (kVK_Command, command | 0x08),
            (kVK_RightCommand, command | 0x08 | 0x10),
            (kVK_RightCommand, command | 0x08),
            (kVK_Command, 0)
        ]
        var result: [CGEvent] = []
        for (code, flags) in states {
            guard let event = CGEvent(keyboardEventSource: nil,
                                      virtualKey: CGKeyCode(code), keyDown: true) else { return nil }
            event.type = .flagsChanged
            event.flags = CGEventFlags(rawValue: flags)
            result.append(event)
        }
        return result
    }
}
