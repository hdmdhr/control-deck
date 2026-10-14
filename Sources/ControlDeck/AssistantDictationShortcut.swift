import AppKit
import Carbon.HIToolbox

/// Native shortcuts verified from the respective application's dictation tooltip.
struct AssistantDictationShortcut {
    let bundleIdentifier: String
    let keyCode: Int
    let flags: CGEventFlags

    static func shortcut(for action: MappedAction) -> AssistantDictationShortcut? {
        switch action {
        case .cursorDictation:
            AssistantDictationShortcut(bundleIdentifier: "com.todesktop.230313mzl4w4u92",
                                       keyCode: kVK_ANSI_M, flags: .maskControl)
        case .grokDictation:
            AssistantDictationShortcut(bundleIdentifier: "com.anysphere.sand",
                                       keyCode: kVK_ANSI_D, flags: .maskCommand)
        default:
            nil
        }
    }
}
