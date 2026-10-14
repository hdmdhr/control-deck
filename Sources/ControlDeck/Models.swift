import AppKit
import Foundation

enum ControllerFamily: String, Codable, CaseIterable, Identifiable, Sendable {
    case dualSense
    case dualShock4
    case switchPro
    case switchPro2
    case eightBitDo
    case generic

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dualSense: String(localized: "DualSense", bundle: AppResources.localizationBundle)
        case .dualShock4: String(localized: "DualShock 4", bundle: AppResources.localizationBundle)
        case .switchPro: String(localized: "Switch Pro", bundle: AppResources.localizationBundle)
        case .switchPro2: String(localized: "Switch 2 Pro", bundle: AppResources.localizationBundle)
        case .eightBitDo: String(localized: "8BitDo", bundle: AppResources.localizationBundle)
        case .generic: String(localized: "Game controller", bundle: AppResources.localizationBundle)
        }
    }

    var isDualSense: Bool { self == .dualSense }

    static func identify(vendorName: String?, productCategory: String) -> Self {
        let identity = "\(vendorName ?? "") \(productCategory)".lowercased()
        if identity.contains("dualsense") || identity.contains("ps5") {
            return .dualSense
        }
        if identity.contains("dualshock") || identity.contains("ps4") {
            return .dualShock4
        }
        if identity.contains("8bitdo") {
            return .eightBitDo
        }
        if identity.contains("switch 2") {
            return .switchPro2
        }
        if identity.contains("switch") || identity.contains("nintendo") {
            return .switchPro
        }
        return .generic
    }
}

enum CodexTaskState: String, Codable, CaseIterable, Sendable {
    case disconnected
    case idle
    case thinking
    case complete
    case needsInput
    case error
    case listening
    case processingVoice

    var label: String {
        switch self {
        case .disconnected: String(localized: "Disconnected", bundle: AppResources.localizationBundle)
        case .idle: String(localized: "Idle", bundle: AppResources.localizationBundle)
        case .thinking: String(localized: "Thinking", bundle: AppResources.localizationBundle)
        case .complete: String(localized: "Complete", bundle: AppResources.localizationBundle)
        case .needsInput: String(localized: "Needs input", bundle: AppResources.localizationBundle)
        case .error: String(localized: "Error", bundle: AppResources.localizationBundle)
        case .listening: String(localized: "Listening", bundle: AppResources.localizationBundle)
        case .processingVoice: String(localized: "Processing voice", bundle: AppResources.localizationBundle)
        }
    }

    var color: NSColor {
        switch self {
        case .disconnected: .systemGray
        case .idle: NSColor(red: 0.08, green: 0.35, blue: 1, alpha: 1)
        case .thinking: NSColor(red: 0.58, green: 0.22, blue: 1, alpha: 1)
        case .complete: NSColor(red: 0.05, green: 0.82, blue: 0.35, alpha: 1)
        case .needsInput: NSColor(red: 1, green: 0.58, blue: 0.05, alpha: 1)
        case .error: NSColor(red: 1, green: 0.12, blue: 0.12, alpha: 1)
        case .listening: NSColor(red: 0, green: 0.88, blue: 0.82, alpha: 1)
        case .processingVoice: .white
        }
    }

    static func aggregate(_ states: [CodexTaskState]) -> CodexTaskState {
        if states.contains(.needsInput) { return .needsInput }
        if states.contains(.error) { return .error }
        if states.contains(.thinking) { return .thinking }
        if states.contains(.complete) { return .complete }
        return states.isEmpty ? .idle : states[0]
    }
}

struct RecentCodexTask: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let latestMessage: String
    let rolloutPath: String
    let updatedAt: Date
    let state: CodexTaskState

    init(
        id: String,
        title: String,
        latestMessage: String? = nil,
        rolloutPath: String,
        updatedAt: Date,
        state: CodexTaskState
    ) {
        self.id = id
        self.title = title
        let trimmedMessage = latestMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedMessage, !trimmedMessage.isEmpty {
            self.latestMessage = trimmedMessage
        } else {
            self.latestMessage = title
        }
        self.rolloutPath = rolloutPath
        self.updatedAt = updatedAt
        self.state = state
    }

    var shortTitle: String {
        shortened(title, limit: 64)
    }

    var shortMessage: String {
        shortened(latestMessage, limit: 140)
    }

    var hasDistinctTitle: Bool {
        normalized(title) != normalized(latestMessage)
    }

    private func shortened(_ value: String, limit: Int) -> String {
        let trimmed = normalized(value)
        if trimmed.count <= limit { return trimmed }
        return String(trimmed.prefix(limit - 1)) + "…"
    }

    private func normalized(_ value: String) -> String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

enum ControllerEvent: Equatable, Sendable {
    case button(ControllerInput, pressed: Bool)
    case stick(ControllerStick, x: Float, y: Float)
    case touch(TouchFinger, x: Float, y: Float, active: Bool)
    case action(ControllerAction)
    case pushToTalk(Bool)
    case microphoneButton
    case motion(ControllerMotionSample)
}

enum ControllerAction: String, CaseIterable, Codable, Sendable {
    case sendMessage
    case interrupt
    case toggleReview
    case togglePlan
    case newTask
    case commandMenu
    case focusCodex
    case previousTask
    case nextTask
    case back
    case forward
    case toggleSidebar
    case quickChat
    case toggleTerminal
    case approve
    case decline
    case continueInNewTask
    case toggleFastMode
    case reasoning

    var label: String {
        switch self {
        case .sendMessage: String(localized: "Send message", bundle: AppResources.localizationBundle)
        case .interrupt: String(localized: "Stop", bundle: AppResources.localizationBundle)
        case .toggleReview: String(localized: "Review changes", bundle: AppResources.localizationBundle)
        case .togglePlan: String(localized: "Toggle Plan mode", bundle: AppResources.localizationBundle)
        case .newTask: String(localized: "New task", bundle: AppResources.localizationBundle)
        case .commandMenu: String(localized: "Command menu", bundle: AppResources.localizationBundle)
        case .focusCodex: String(localized: "Focus Codex", bundle: AppResources.localizationBundle)
        case .previousTask: String(localized: "Previous task", bundle: AppResources.localizationBundle)
        case .nextTask: String(localized: "Next task", bundle: AppResources.localizationBundle)
        case .back: String(localized: "Back", bundle: AppResources.localizationBundle)
        case .forward: String(localized: "Forward", bundle: AppResources.localizationBundle)
        case .toggleSidebar: String(localized: "Toggle sidebar", bundle: AppResources.localizationBundle)
        case .quickChat: String(localized: "Quick chat", bundle: AppResources.localizationBundle)
        case .toggleTerminal: String(localized: "Toggle terminal", bundle: AppResources.localizationBundle)
        case .approve: String(localized: "Approve", bundle: AppResources.localizationBundle)
        case .decline: String(localized: "Decline", bundle: AppResources.localizationBundle)
        case .continueInNewTask: String(localized: "Continue in new task", bundle: AppResources.localizationBundle)
        case .toggleFastMode: String(localized: "Toggle Fast mode", bundle: AppResources.localizationBundle)
        case .reasoning: String(localized: "Reasoning effort", bundle: AppResources.localizationBundle)
        }
    }
}

enum HapticCue: Sendable {
    case connect
    case success
    case selection
    case warning
    case error
    case listeningStart
    case listeningStop
}

enum FeedbackSoundCue: Sendable {
    case complete
    case needsInput
    case error
    case listeningStart
    case listeningStop
}

struct FeedbackTone: Sendable {
    let frequency: Float
    let duration: TimeInterval
    let volume: Float
    let pauseAfter: TimeInterval
}

enum SoundTheme: String, Codable, CaseIterable, Identifiable, Sendable {
    case off
    case playful
    case soft
    case arcade

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: String(localized: "Off", bundle: AppResources.localizationBundle)
        case .playful: String(localized: "Playful", bundle: AppResources.localizationBundle)
        case .soft: String(localized: "Soft", bundle: AppResources.localizationBundle)
        case .arcade: String(localized: "Arcade", bundle: AppResources.localizationBundle)
        }
    }

    var detail: String {
        switch self {
        case .off: String(localized: "Haptics only", bundle: AppResources.localizationBundle)
        case .playful: String(localized: "Bright, short and friendly", bundle: AppResources.localizationBundle)
        case .soft: String(localized: "Warm and understated", bundle: AppResources.localizationBundle)
        case .arcade: String(localized: "Crisp retro chirps", bundle: AppResources.localizationBundle)
        }
    }

    func tones(for cue: FeedbackSoundCue) -> [FeedbackTone] {
        guard self != .off else { return [] }
        switch (self, cue) {
        case (.playful, .complete):
            return [
                .init(frequency: 587, duration: 0.07, volume: 0.055, pauseAfter: 0.018),
                .init(frequency: 784, duration: 0.08, volume: 0.060, pauseAfter: 0.018),
                .init(frequency: 1_047, duration: 0.11, volume: 0.052, pauseAfter: 0)
            ]
        case (.playful, .needsInput):
            return [
                .init(frequency: 740, duration: 0.07, volume: 0.045, pauseAfter: 0.035),
                .init(frequency: 740, duration: 0.07, volume: 0.045, pauseAfter: 0)
            ]
        case (.playful, .error):
            return [
                .init(frequency: 330, duration: 0.09, volume: 0.050, pauseAfter: 0.025),
                .init(frequency: 247, duration: 0.12, volume: 0.045, pauseAfter: 0)
            ]
        case (.playful, .listeningStart):
            return [.init(frequency: 880, duration: 0.07, volume: 0.040, pauseAfter: 0)]
        case (.playful, .listeningStop):
            return [.init(frequency: 659, duration: 0.07, volume: 0.038, pauseAfter: 0)]
        case (.soft, .complete):
            return [
                .init(frequency: 523, duration: 0.11, volume: 0.035, pauseAfter: 0.025),
                .init(frequency: 659, duration: 0.16, volume: 0.035, pauseAfter: 0)
            ]
        case (.soft, .needsInput):
            return [.init(frequency: 587, duration: 0.12, volume: 0.030, pauseAfter: 0)]
        case (.soft, .error):
            return [.init(frequency: 294, duration: 0.16, volume: 0.032, pauseAfter: 0)]
        case (.soft, .listeningStart):
            return [.init(frequency: 698, duration: 0.08, volume: 0.027, pauseAfter: 0)]
        case (.soft, .listeningStop):
            return [.init(frequency: 523, duration: 0.08, volume: 0.025, pauseAfter: 0)]
        case (.arcade, .complete):
            return [
                .init(frequency: 660, duration: 0.045, volume: 0.050, pauseAfter: 0.012),
                .init(frequency: 990, duration: 0.045, volume: 0.050, pauseAfter: 0.012),
                .init(frequency: 1_320, duration: 0.08, volume: 0.045, pauseAfter: 0)
            ]
        case (.arcade, .needsInput):
            return [
                .init(frequency: 880, duration: 0.045, volume: 0.045, pauseAfter: 0.025),
                .init(frequency: 880, duration: 0.045, volume: 0.045, pauseAfter: 0)
            ]
        case (.arcade, .error):
            return [
                .init(frequency: 440, duration: 0.05, volume: 0.048, pauseAfter: 0.015),
                .init(frequency: 220, duration: 0.09, volume: 0.045, pauseAfter: 0)
            ]
        case (.arcade, .listeningStart):
            return [.init(frequency: 1_100, duration: 0.045, volume: 0.040, pauseAfter: 0)]
        case (.arcade, .listeningStop):
            return [.init(frequency: 550, duration: 0.045, volume: 0.038, pauseAfter: 0)]
        case (.off, _):
            return []
        }
    }
}

struct ControllerPreferences {
    private enum Key {
        static let soundTheme = "soundTheme.v2"
        static let statusHaptics = "statusHaptics"
        static let generalDictationEngine = "generalDictationEngine.v1"
        static let generalDictationUsesControllerMicrophone =
            "generalDictationUsesControllerMicrophone.v1"
    }

    static var soundTheme: SoundTheme {
        get {
            guard let value = UserDefaults.standard.string(
                forKey: Key.soundTheme
            ) else {
                return .off
            }
            return SoundTheme(rawValue: value) ?? .off
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Key.soundTheme)
        }
    }

    static var statusHaptics: Bool {
        get {
            if UserDefaults.standard.object(forKey: Key.statusHaptics) == nil { return true }
            return UserDefaults.standard.bool(forKey: Key.statusHaptics)
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.statusHaptics) }
    }

    static var generalDictationEngine: GeneralDictationEngine {
        get {
            guard let rawValue = UserDefaults.standard.string(
                forKey: Key.generalDictationEngine
            ) else {
                return .appleSpeech
            }
            return GeneralDictationEngine(rawValue: rawValue) ?? .appleSpeech
        }
        set {
            UserDefaults.standard.set(
                newValue.rawValue,
                forKey: Key.generalDictationEngine
            )
        }
    }

    static var generalDictationUsesControllerMicrophone: Bool {
        get {
            if UserDefaults.standard.object(
                forKey: Key.generalDictationUsesControllerMicrophone
            ) == nil {
                return true
            }
            return UserDefaults.standard.bool(
                forKey: Key.generalDictationUsesControllerMicrophone
            )
        }
        set {
            UserDefaults.standard.set(
                newValue,
                forKey: Key.generalDictationUsesControllerMicrophone
            )
        }
    }
}

enum GeneralDictationEngine: String, CaseIterable, Hashable, Identifiable {
    case appleSpeech
    case parakeetEOU120M
    case whisperKitBaseEnglish
    case whisperKitSmallEnglish

    var id: String { rawValue }

    var label: String {
        switch self {
        case .appleSpeech:
            String(localized: "System", bundle: AppResources.localizationBundle)
        case .parakeetEOU120M:
            String(localized: "Live", bundle: AppResources.localizationBundle)
        case .whisperKitBaseEnglish:
            String(localized: "Balanced", bundle: AppResources.localizationBundle)
        case .whisperKitSmallEnglish:
            String(localized: "High Accuracy", bundle: AppResources.localizationBundle)
        }
    }

    var engineName: String {
        switch self {
        case .appleSpeech:
            "Apple SpeechTranscriber"
        case .parakeetEOU120M:
            "Parakeet EOU 120M"
        case .whisperKitBaseEnglish:
            "WhisperKit Base English"
        case .whisperKitSmallEnglish:
            "WhisperKit Small English"
        }
    }

    var detail: String {
        switch self {
        case .appleSpeech:
            String(localized: "Apple SpeechTranscriber · built into macOS 26", bundle: AppResources.localizationBundle)
        case .parakeetEOU120M:
            String(localized: "Parakeet EOU · live local text with automatic fallback", bundle: AppResources.localizationBundle)
        case .whisperKitBaseEnglish:
            String(localized: "WhisperKit Base English · compact local transcription", bundle: AppResources.localizationBundle)
        case .whisperKitSmallEnglish:
            String(localized: "WhisperKit Small English · optional higher-accuracy model", bundle: AppResources.localizationBundle)
        }
    }

    var isWhisperKit: Bool {
        self == .whisperKitBaseEnglish ||
            self == .whisperKitSmallEnglish
    }

    var estimatedDownloadBytes: Int64 {
        switch self {
        case .appleSpeech:
            0
        case .parakeetEOU120M:
            224_000_000
        case .whisperKitBaseEnglish:
            149_000_000
        case .whisperKitSmallEnglish:
            487_000_000
        }
    }
}
