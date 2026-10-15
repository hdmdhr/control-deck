import Foundation

extension ControllerProfile {
    static let finder = ControllerProfile(
        kind: .finder,
        name: "Finder",
        bundleIdentifiers: ["com.apple.finder"],
        bindings: mapping([
            .cross: .mouseLeftClick, .circle: .mouseRightClick,
            .square: .copy, .triangle: .paste,
            .l1: .back, .r1: .forward,
            .l2: .systemDictation, .r2: .codexAppSnapshot,
            .l3: .browserFind, .r3: .spaceKey,
            .create: .browserNewTab, .options: .escapeKey,
            .ps: .openCodex,
            .dpadUp: .arrowUp, .dpadDown: .arrowDown,
            .dpadLeft: .arrowLeft, .dpadRight: .arrowRight,
            .touchpadClick: .showControllerOverlay,
            .microphone: .systemDictation
        ]),
        pointer: .generalDefault,
        touchpad: .trackpadDefault
    )

    static let meetings = ControllerProfile(
        kind: .meetings,
        name: "Meetings",
        bundleIdentifiers: [
            "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams"
        ],
        windowTitleKeywords: ["Google Meet"],
        bindings: mapping([
            .cross: .mouseLeftClick, .circle: .escapeKey,
            .square: .meetingChat, .triangle: .meetingRaiseHand,
            .l1: .meetingParticipants, .r1: .meetingShare,
            .l2: .systemDictation, .r2: .codexAppSnapshot,
            .l3: .meetingMute, .r3: .meetingVideo,
            .create: .systemDictation, .options: .meetingChat,
            .ps: .openCodex,
            .dpadUp: .volumeUp, .dpadDown: .volumeDown,
            .dpadLeft: .meetingMute, .dpadRight: .meetingVideo,
            .touchpadClick: .showControllerOverlay,
            .microphone: .systemDictation
        ]),
        pointer: .generalDefault,
        touchpad: .trackpadDefault
    )

    static let presentations = ControllerProfile(
        kind: .presentations,
        name: "Presentations",
        bundleIdentifiers: [
            "com.apple.iWork.Keynote", "com.microsoft.Powerpoint"
        ],
        windowTitleKeywords: ["Google Slides"],
        bindings: mapping([
            .cross: .presentationNext, .circle: .presentationPrevious,
            .square: .presentationBlackScreen, .triangle: .presentationStart,
            .l1: .presentationPrevious, .r1: .presentationNext,
            .l2: .systemDictation, .r2: .codexAppSnapshot,
            .l3: .presentationNotesDown, .r3: .presentationNotesUp,
            .create: .presentationStart, .options: .presentationExit,
            .ps: .openCodex,
            .dpadUp: .presentationNotesUp, .dpadDown: .presentationNotesDown,
            .dpadLeft: .presentationPrevious, .dpadRight: .presentationNext,
            .touchpadClick: .showControllerOverlay,
            .microphone: .systemDictation
        ]),
        pointer: .generalDefault,
        touchpad: .trackpadDefault
    )

    static let slack = ControllerProfile(
        kind: .slack,
        name: "Slack",
        bundleIdentifiers: ["com.tinyspeck.slackmacgap"],
        windowTitleKeywords: ["Slack"],
        bindings: mapping([
            .cross: .mouseLeftClick, .circle: .escapeKey,
            .square: .slackThreads, .triangle: .slackActivity,
            .l1: .back, .r1: .forward,
            .l2: .systemDictation, .r2: .codexAppSnapshot,
            .l3: .slackJumpConversation, .r3: .slackHuddle,
            .create: .slackJumpConversation, .options: .escapeKey,
            .ps: .openCodex,
            .dpadUp: .arrowUp, .dpadDown: .arrowDown,
            .dpadLeft: .slackPreviousUnread, .dpadRight: .slackNextUnread,
            .touchpadClick: .showControllerOverlay,
            .microphone: .systemDictation
        ]),
        pointer: .generalDefault,
        touchpad: .trackpadDefault
    )

    static let mail = ControllerProfile(
        kind: .mail,
        name: "Mail",
        bundleIdentifiers: ["com.apple.mail", "com.microsoft.Outlook"],
        bindings: mapping([
            .cross: .mouseLeftClick, .circle: .escapeKey,
            .square: .mailArchive, .triangle: .mailReply,
            .l1: .back, .r1: .forward,
            .l2: .systemDictation, .r2: .codexAppSnapshot,
            .l3: .browserFind, .r3: .mailUnread,
            .create: .systemDictation, .options: .escapeKey,
            .ps: .openCodex,
            .dpadUp: .arrowUp, .dpadDown: .arrowDown,
            .dpadLeft: .back, .dpadRight: .forward,
            .touchpadClick: .showControllerOverlay,
            .microphone: .systemDictation
        ]),
        pointer: .generalDefault,
        touchpad: .trackpadDefault
    )

    static let photos = ControllerProfile(
        kind: .photos,
        name: "Photos",
        bundleIdentifiers: ["com.apple.Photos"],
        bindings: mapping([
            .cross: .mouseLeftClick, .circle: .escapeKey,
            .square: .photosFavorite, .triangle: .photosEdit,
            .l1: .arrowLeft, .r1: .arrowRight,
            .l2: .systemDictation, .r2: .codexAppSnapshot,
            .l3: .photosInfo, .r3: .photosRotate,
            .create: .systemDictation, .options: .escapeKey,
            .ps: .openCodex,
            .dpadUp: .zoomIn, .dpadDown: .zoomOut,
            .dpadLeft: .arrowLeft, .dpadRight: .arrowRight,
            .touchpadClick: .showControllerOverlay,
            .microphone: .systemDictation
        ]),
        pointer: .generalDefault,
        touchpad: .trackpadDefault
    )

    static let figma = ControllerProfile(
        kind: .figma,
        name: "Figma",
        bundleIdentifiers: ["com.figma.Desktop"],
        windowTitleKeywords: ["Figma"],
        bindings: mapping([
            .cross: .mouseLeftClick, .circle: .escapeKey,
            .square: .figmaFrame, .triangle: .figmaComment,
            .l1: .undo, .r1: .redo,
            .l2: .systemDictation, .r2: .codexAppSnapshot,
            .l3: .figmaHand, .r3: .figmaDevMode,
            .create: .systemDictation, .options: .escapeKey,
            .ps: .openCodex,
            .dpadUp: .zoomIn, .dpadDown: .zoomOut,
            .dpadLeft: .undo, .dpadRight: .redo,
            .touchpadClick: .showControllerOverlay,
            .microphone: .systemDictation
        ]),
        pointer: .generalDefault,
        touchpad: .trackpadDefault
    )

    static let videoEditing = ControllerProfile(
        kind: .videoEditing,
        name: "Video editing",
        bundleIdentifiers: [
            "com.apple.FinalCut", "com.blackmagic-design.DaVinciResolve*",
            "com.adobe.PremierePro*"
        ],
        bindings: mapping([
            .cross: .timelinePlayPause, .circle: .escapeKey,
            .square: .timelineMarkIn, .triangle: .timelineMarkOut,
            .l1: .timelinePreviousEdit, .r1: .timelineNextEdit,
            .l2: .systemDictation, .r2: .codexAppSnapshot,
            .l3: .timelinePause, .r3: .screenshotSelection,
            .create: .systemDictation, .options: .escapeKey,
            .ps: .openCodex,
            .dpadUp: .timelinePreviousEdit, .dpadDown: .timelineNextEdit,
            .dpadLeft: .arrowLeft, .dpadRight: .arrowRight,
            .touchpadClick: .showControllerOverlay,
            .microphone: .systemDictation
        ]),
        pointer: .generalDefault,
        touchpad: .trackpadDefault
    )

    static let logic = ControllerProfile(
        kind: .logic,
        name: "Logic Pro",
        bundleIdentifiers: ["com.apple.logic10"],
        bindings: mapping([
            .cross: .timelinePlayPause, .circle: .escapeKey,
            .square: .timelineRewind, .triangle: .timelineFastForward,
            .l1: .timelineRewind, .r1: .timelineFastForward,
            .l2: .systemDictation, .r2: .codexAppSnapshot,
            .l3: .volumeDown, .r3: .volumeUp,
            .create: .systemDictation, .options: .escapeKey,
            .ps: .openCodex,
            .dpadUp: .volumeUp, .dpadDown: .volumeDown,
            .dpadLeft: .timelineRewind, .dpadRight: .timelineFastForward,
            .touchpadClick: .showControllerOverlay,
            .microphone: .systemDictation
        ]),
        pointer: .generalDefault,
        touchpad: .trackpadDefault
    )

    static let terminal = ControllerProfile(
        kind: .terminal,
        name: "Terminal",
        bundleIdentifiers: [
            "com.apple.Terminal", "com.googlecode.iterm2",
            "dev.warp.Warp-Stable", "com.mitchellh.ghostty"
        ],
        bindings: mapping([
            .cross: .mouseLeftClick, .circle: .escapeKey,
            .square: .copy, .triangle: .paste,
            .l1: .terminalPreviousTab, .r1: .terminalNextTab,
            .l2: .systemDictation, .r2: .codexAppSnapshot,
            .l3: .terminalSearchHistory, .r3: .terminalClear,
            .create: .terminalNewTab, .options: .terminalCloseTab,
            .ps: .openCodex,
            .dpadUp: .arrowUp, .dpadDown: .arrowDown,
            .dpadLeft: .arrowLeft, .dpadRight: .arrowRight,
            .touchpadClick: .showControllerOverlay,
            .microphone: .systemDictation
        ]),
        pointer: .generalDefault,
        touchpad: .trackpadDefault
    )
}

extension ProfileKind {
    var preferredActionCategories: [ActionCategory] {
        let common: [ActionCategory] = [.mouse, .navigation, .keyboard, .other]
        switch self {
        case .codex: return [.codex] + common
        case .claude: return [.claude] + common
        case .meetings: return [.meeting] + common
        case .presentations: return [.presentation] + common
        case .slack: return [.slack] + common
        case .mail: return [.mail] + common
        case .photos, .finder: return [.files] + common
        case .figma, .videoEditing, .logic: return [.creative] + common
        case .terminal: return [.terminal] + common
        case .chrome: return [.browser] + common
        case .spotify: return [.media] + common
        case .general: return common
        case .cursor: return [.cursor, .communication, .terminal] + common
        case .grokBot: return [.grokBot, .communication] + common
        case .xcode: return [.codex, .terminal] + common
        }
    }
}
