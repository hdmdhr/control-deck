import Foundation

/// Strict semantic candidates; localized labels still require native app verification.
/// Never substitute a keyboard shortcut, send button, or voice-mode control.
enum CodexDictationIntent: Equatable {
    case start
    case stopAndInsert

    var exactLabels: [String] {
        switch self {
        case .start:
            ["听写", "聽寫", "Dictate", "Start dictation", "音声入力"]
        case .stopAndInsert:
            ["停止听写", "停止聽寫", "Stop dictation", "Stop and insert", "音声入力を停止"]
        }
    }

    func matches(_ labels: [String]) -> Bool {
        NativeCodexSemanticMatch.matches(labels: labels, exact: exactLabels,
                                         isButton: true, enabled: true, pressable: true)
    }


}

/// Shared by AX traversal and the logic tests; uncertain or ineligible controls
/// cannot become candidates even if their visible text resembles the action.
enum NativeCodexSemanticMatch {
    static func matches(labels: [String], exact: [String], isButton: Bool,
                        enabled: Bool, pressable: Bool) -> Bool {
        isButton && enabled && pressable && labels.contains {
            exact.contains($0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    static func isUnique(desiredCount: Int, opposingCount: Int,
                         traversalComplete: Bool) -> Bool {
        traversalComplete && desiredCount == 1 && opposingCount == 0
    }
}
