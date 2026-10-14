import Foundation

enum ControllerTransport: String, Codable, CaseIterable, Sendable {
    case usb
    case bluetooth
    case unknown

    var label: String {
        switch self {
        case .usb: String(localized: "USB", bundle: AppResources.localizationBundle)
        case .bluetooth: String(localized: "Bluetooth", bundle: AppResources.localizationBundle)
        case .unknown: String(localized: "Wireless / USB", bundle: AppResources.localizationBundle)
        }
    }

    var systemImage: String {
        switch self {
        case .usb: "cable.connector"
        case .bluetooth: "bluetooth"
        case .unknown: "gamecontroller"
        }
    }
}

enum ControllerInput: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case cross
    case circle
    case square
    case triangle
    case dpadUp
    case dpadDown
    case dpadLeft
    case dpadRight
    case l1
    case r1
    case l2
    case r2
    case l3
    case r3
    case create
    case options
    case ps
    case touchpadClick
    case microphone

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cross: String(localized: "Cross", bundle: AppResources.localizationBundle)
        case .circle: String(localized: "Circle", bundle: AppResources.localizationBundle)
        case .square: String(localized: "Square", bundle: AppResources.localizationBundle)
        case .triangle: String(localized: "Triangle", bundle: AppResources.localizationBundle)
        case .dpadUp: String(localized: "D-pad Up", bundle: AppResources.localizationBundle)
        case .dpadDown: String(localized: "D-pad Down", bundle: AppResources.localizationBundle)
        case .dpadLeft: String(localized: "D-pad Left", bundle: AppResources.localizationBundle)
        case .dpadRight: String(localized: "D-pad Right", bundle: AppResources.localizationBundle)
        case .l1: String(localized: "L1", bundle: AppResources.localizationBundle)
        case .r1: String(localized: "R1", bundle: AppResources.localizationBundle)
        case .l2: String(localized: "L2", bundle: AppResources.localizationBundle)
        case .r2: String(localized: "R2", bundle: AppResources.localizationBundle)
        case .l3: String(localized: "L3", bundle: AppResources.localizationBundle)
        case .r3: String(localized: "R3", bundle: AppResources.localizationBundle)
        case .create: String(localized: "Create", bundle: AppResources.localizationBundle)
        case .options: String(localized: "Options", bundle: AppResources.localizationBundle)
        case .ps: String(localized: "PS", bundle: AppResources.localizationBundle)
        case .touchpadClick: String(localized: "Touchpad Click", bundle: AppResources.localizationBundle)
        case .microphone: String(localized: "Microphone", bundle: AppResources.localizationBundle)
        }
    }

    var shortLabel: String {
        switch self {
        case .dpadUp: "↑"
        case .dpadDown: "↓"
        case .dpadLeft: "←"
        case .dpadRight: "→"
        case .touchpadClick: String(localized: "Pad", bundle: AppResources.localizationBundle)
        case .microphone: String(localized: "Mic", bundle: AppResources.localizationBundle)
        default: label
        }
    }
}

enum AppSwitcherHoldResponse: Equatable, Sendable {
    case passThrough
    case deferTouchpadTap(generation: Int)
    case performTouchpadTap
    case forward
    case backward
    case select
    case cancel
    case consume
}

struct AppSwitcherHoldGate: Sendable {
    private(set) var isActive = false
    private var touchpadPressed = false
    private var touchpadTapPending = false
    private var generation = 0

    mutating func handle(
        _ input: ControllerInput,
        pressed: Bool
    ) -> AppSwitcherHoldResponse {
        if input == .touchpadClick {
            if pressed {
                guard !touchpadPressed else { return .consume }
                touchpadPressed = true
                touchpadTapPending = true
                generation += 1
                return .deferTouchpadTap(generation: generation)
            }

            touchpadPressed = false
            generation += 1
            if isActive {
                isActive = false
                touchpadTapPending = false
                return .select
            }
            if touchpadTapPending {
                touchpadTapPending = false
                return .performTouchpadTap
            }
            return .consume
        }

        guard isActive else {
            return touchpadPressed ? .consume : .passThrough
        }

        guard pressed else { return .consume }
        switch input {
        case .dpadRight:
            return .forward
        case .dpadLeft:
            return .backward
        case .circle:
            isActive = false
            touchpadTapPending = false
            generation += 1
            return .cancel
        default:
            return .consume
        }
    }

    mutating func activate(generation expected: Int) -> Bool {
        guard touchpadPressed,
              touchpadTapPending,
              generation == expected,
              !isActive
        else {
            return false
        }
        touchpadTapPending = false
        isActive = true
        return true
    }

    mutating func cancel() -> Bool {
        let shouldReleaseCommand = isActive
        generation += 1
        touchpadPressed = false
        touchpadTapPending = false
        isActive = false
        return shouldReleaseCommand
    }
}

enum AppSwitcherStickDirection: Equatable, Sendable {
    case forward
    case backward
}

struct AppSwitcherStickGate: Sendable {
    private var isCentered = true

    mutating func update(x: Float) -> AppSwitcherStickDirection? {
        if abs(x) <= 0.35 {
            isCentered = true
            return nil
        }
        guard isCentered, abs(x) >= 0.68 else { return nil }
        isCentered = false
        return x > 0 ? .forward : .backward
    }

    mutating func reset() {
        isCentered = true
    }
}

enum ControllerStick: String, Codable, CaseIterable, Identifiable, Sendable {
    case off
    case left
    case right

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: String(localized: "Off", bundle: AppResources.localizationBundle)
        case .left: String(localized: "Left stick", bundle: AppResources.localizationBundle)
        case .right: String(localized: "Right stick", bundle: AppResources.localizationBundle)
        }
    }
}

enum TouchFinger: String, Codable, Sendable {
    case primary
    case secondary
}

enum TouchGesture: String, Codable, CaseIterable, Identifiable, Sendable {
    case oneFingerTap
    case twoFingerTap
    case oneFingerLongPress
    case twoFingerLongPress
    case oneFingerSwipeLeft
    case oneFingerSwipeRight
    case oneFingerSwipeUp
    case oneFingerSwipeDown
    case twoFingerSwipeLeft
    case twoFingerSwipeRight
    case twoFingerSwipeUp
    case twoFingerSwipeDown

    var id: String { rawValue }

    var label: String {
        switch self {
        case .oneFingerTap: String(localized: "One-finger tap", bundle: AppResources.localizationBundle)
        case .twoFingerTap: String(localized: "Two-finger tap", bundle: AppResources.localizationBundle)
        case .oneFingerLongPress: String(localized: "One-finger hold", bundle: AppResources.localizationBundle)
        case .twoFingerLongPress: String(localized: "Two-finger hold", bundle: AppResources.localizationBundle)
        case .oneFingerSwipeLeft: String(localized: "One-finger swipe left", bundle: AppResources.localizationBundle)
        case .oneFingerSwipeRight: String(localized: "One-finger swipe right", bundle: AppResources.localizationBundle)
        case .oneFingerSwipeUp: String(localized: "One-finger swipe up", bundle: AppResources.localizationBundle)
        case .oneFingerSwipeDown: String(localized: "One-finger swipe down", bundle: AppResources.localizationBundle)
        case .twoFingerSwipeLeft: String(localized: "Two-finger swipe left", bundle: AppResources.localizationBundle)
        case .twoFingerSwipeRight: String(localized: "Two-finger swipe right", bundle: AppResources.localizationBundle)
        case .twoFingerSwipeUp: String(localized: "Two-finger swipe up", bundle: AppResources.localizationBundle)
        case .twoFingerSwipeDown: String(localized: "Two-finger swipe down", bundle: AppResources.localizationBundle)
        }
    }

    static func swipe(fingers: Int, deltaX: Float, deltaY: Float) -> TouchGesture {
        let horizontal = abs(deltaX) >= abs(deltaY)
        if fingers >= 2 {
            if horizontal {
                return deltaX < 0 ? .twoFingerSwipeLeft : .twoFingerSwipeRight
            }
            return deltaY < 0 ? .twoFingerSwipeDown : .twoFingerSwipeUp
        }
        if horizontal {
            return deltaX < 0 ? .oneFingerSwipeLeft : .oneFingerSwipeRight
        }
        return deltaY < 0 ? .oneFingerSwipeDown : .oneFingerSwipeUp
    }
}

enum ActionCategory: String, CaseIterable, Identifiable, Sendable {
    case codex
    case claude
    case meeting
    case presentation
    case communication
    case files
    case creative
    case terminal
    case mouse
    case navigation
    case keyboard
    case browser
    case media
    case apps
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .codex: String(localized: "Codex", bundle: AppResources.localizationBundle)
        case .claude: String(localized: "Claude", bundle: AppResources.localizationBundle)
        case .meeting: String(localized: "Meetings", bundle: AppResources.localizationBundle)
        case .presentation: String(localized: "Presentations", bundle: AppResources.localizationBundle)
        case .communication: String(localized: "Communication", bundle: AppResources.localizationBundle)
        case .files: String(localized: "Files & photos", bundle: AppResources.localizationBundle)
        case .creative: String(localized: "Creative tools", bundle: AppResources.localizationBundle)
        case .terminal: String(localized: "Terminal", bundle: AppResources.localizationBundle)
        default: rawValue.capitalized
        }
    }
}

enum MappedAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case none

    case codexSend
    case codexStop
    case codexReview
    case codexPlan
    case codexNewTask
    case codexCommandMenu
    case codexFocus
    case codexPreviousTask
    case codexNextTask
    case codexBack
    case codexForward
    case codexSidebar
    case codexQuickChat
    case codexTerminal
    case codexApprove
    case codexDecline
    case codexDictation
    case codexAppSnapshot
    case codexFastMode
    case codexContinueInNewTask

    case claudeNewChat
    case claudeSidebar
    case claudeCode
    case claudeProjects

    case meetingMute
    case meetingPushToTalk
    case meetingVideo
    case meetingChat
    case meetingParticipants
    case meetingShare
    case meetingRaiseHand

    case presentationStart
    case presentationNext
    case presentationPrevious
    case presentationBlackScreen
    case presentationPointer
    case presentationNotesUp
    case presentationNotesDown
    case presentationExit

    case slackJumpConversation
    case slackPreviousUnread
    case slackNextUnread
    case slackThreads
    case slackActivity
    case slackHuddle

    case mailArchive
    case mailReply
    case mailUnread

    case photosFavorite
    case photosEdit
    case photosRotate
    case photosInfo

    case timelinePlayPause
    case timelineReverse
    case timelinePause
    case timelineForward
    case timelineMarkIn
    case timelineMarkOut
    case timelinePreviousEdit
    case timelineNextEdit
    case timelineRecord
    case timelineRewind
    case timelineFastForward

    case figmaComment
    case figmaFrame
    case figmaHand
    case figmaDevMode

    case terminalNewTab
    case terminalCloseTab
    case terminalNextTab
    case terminalPreviousTab
    case terminalClear
    case terminalInterrupt
    case terminalSearchHistory
    case terminalSplitPane
    case terminalClosePane

    case mouseLeftClick
    case mouseRightClick
    case mouseMiddleClick
    case screenshotSelection

    case back
    case forward
    case missionControl
    case showDesktop
    case appSwitcher

    case returnKey
    case escapeKey
    case spaceKey
    case tabKey
    case copy
    case paste
    case cut
    case selectAll
    case undo
    case redo
    case zoomIn
    case zoomOut
    case arrowUp
    case arrowDown
    case arrowLeft
    case arrowRight

    case browserAddress
    case browserNewTab
    case browserCloseTab
    case browserReopenTab
    case browserReload
    case browserFind
    case browserNextTab
    case browserPreviousTab

    case mediaPlayPause
    case mediaNext
    case mediaPrevious
    case volumeUp
    case volumeDown
    case volumeMute

    case openCodex
    case openChrome
    case openSpotify
    case openClaude
    case systemDictation
    case cursorDictation
    case grokDictation
    case showControllerOverlay
    case deleteTextWithConfirmation

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: String(localized: "No action", bundle: AppResources.localizationBundle)
        case .codexSend: String(localized: "Codex · Send", bundle: AppResources.localizationBundle)
        case .codexStop: String(localized: "Codex · Stop", bundle: AppResources.localizationBundle)
        case .codexReview: String(localized: "Codex · Review changes", bundle: AppResources.localizationBundle)
        case .codexPlan: String(localized: "Codex · Plan mode", bundle: AppResources.localizationBundle)
        case .codexNewTask: String(localized: "Codex · New task", bundle: AppResources.localizationBundle)
        case .codexCommandMenu: String(localized: "Codex · Command menu", bundle: AppResources.localizationBundle)
        case .codexFocus: String(localized: "Codex · Focus", bundle: AppResources.localizationBundle)
        case .codexPreviousTask: String(localized: "Codex · Previous task", bundle: AppResources.localizationBundle)
        case .codexNextTask: String(localized: "Codex · Next task", bundle: AppResources.localizationBundle)
        case .codexBack: String(localized: "Codex · Back", bundle: AppResources.localizationBundle)
        case .codexForward: String(localized: "Codex · Forward", bundle: AppResources.localizationBundle)
        case .codexSidebar: String(localized: "Codex · Toggle sidebar", bundle: AppResources.localizationBundle)
        case .codexQuickChat: String(localized: "Codex · Quick chat", bundle: AppResources.localizationBundle)
        case .codexTerminal: String(localized: "Codex · Toggle terminal", bundle: AppResources.localizationBundle)
        case .codexApprove: String(localized: "Codex · Approve", bundle: AppResources.localizationBundle)
        case .codexDecline: String(localized: "Codex · Decline", bundle: AppResources.localizationBundle)
        case .codexDictation: String(localized: "Codex · Dictation", bundle: AppResources.localizationBundle)
        case .codexAppSnapshot: String(localized: "Codex · App snapshot", bundle: AppResources.localizationBundle)
        case .codexFastMode: String(localized: "Codex · Fast mode", bundle: AppResources.localizationBundle)
        case .codexContinueInNewTask: String(localized: "Codex · Continue in new task", bundle: AppResources.localizationBundle)
        case .claudeNewChat: String(localized: "Claude · New chat", bundle: AppResources.localizationBundle)
        case .claudeSidebar: String(localized: "Claude · Toggle sidebar", bundle: AppResources.localizationBundle)
        case .claudeCode: String(localized: "Claude · Code", bundle: AppResources.localizationBundle)
        case .claudeProjects: String(localized: "Claude · Projects", bundle: AppResources.localizationBundle)
        case .meetingMute: String(localized: "Meeting · Mute / unmute", bundle: AppResources.localizationBundle)
        case .meetingPushToTalk: String(localized: "Meeting · Push to talk", bundle: AppResources.localizationBundle)
        case .meetingVideo: String(localized: "Meeting · Camera", bundle: AppResources.localizationBundle)
        case .meetingChat: String(localized: "Meeting · Chat", bundle: AppResources.localizationBundle)
        case .meetingParticipants: String(localized: "Meeting · Participants", bundle: AppResources.localizationBundle)
        case .meetingShare: String(localized: "Meeting · Share tray", bundle: AppResources.localizationBundle)
        case .meetingRaiseHand: String(localized: "Meeting · Raise hand", bundle: AppResources.localizationBundle)
        case .presentationStart: String(localized: "Presentation · Start", bundle: AppResources.localizationBundle)
        case .presentationNext: String(localized: "Presentation · Next", bundle: AppResources.localizationBundle)
        case .presentationPrevious: String(localized: "Presentation · Previous", bundle: AppResources.localizationBundle)
        case .presentationBlackScreen: String(localized: "Presentation · Black screen", bundle: AppResources.localizationBundle)
        case .presentationPointer: String(localized: "Presentation · Pointer", bundle: AppResources.localizationBundle)
        case .presentationNotesUp: String(localized: "Presentation · Notes up", bundle: AppResources.localizationBundle)
        case .presentationNotesDown: String(localized: "Presentation · Notes down", bundle: AppResources.localizationBundle)
        case .presentationExit: String(localized: "Presentation · Exit", bundle: AppResources.localizationBundle)
        case .slackJumpConversation: String(localized: "Slack · Jump to conversation", bundle: AppResources.localizationBundle)
        case .slackPreviousUnread: String(localized: "Slack · Previous unread", bundle: AppResources.localizationBundle)
        case .slackNextUnread: String(localized: "Slack · Next unread", bundle: AppResources.localizationBundle)
        case .slackThreads: String(localized: "Slack · Threads", bundle: AppResources.localizationBundle)
        case .slackActivity: String(localized: "Slack · Activity", bundle: AppResources.localizationBundle)
        case .slackHuddle: String(localized: "Slack · Huddle", bundle: AppResources.localizationBundle)
        case .mailArchive: String(localized: "Mail · Archive", bundle: AppResources.localizationBundle)
        case .mailReply: String(localized: "Mail · Reply", bundle: AppResources.localizationBundle)
        case .mailUnread: String(localized: "Mail · Read / unread", bundle: AppResources.localizationBundle)
        case .photosFavorite: String(localized: "Photos · Favourite", bundle: AppResources.localizationBundle)
        case .photosEdit: String(localized: "Photos · Edit", bundle: AppResources.localizationBundle)
        case .photosRotate: String(localized: "Photos · Rotate", bundle: AppResources.localizationBundle)
        case .photosInfo: String(localized: "Photos · Info", bundle: AppResources.localizationBundle)
        case .timelinePlayPause: String(localized: "Timeline · Play / pause", bundle: AppResources.localizationBundle)
        case .timelineReverse: String(localized: "Timeline · Reverse", bundle: AppResources.localizationBundle)
        case .timelinePause: String(localized: "Timeline · Pause", bundle: AppResources.localizationBundle)
        case .timelineForward: String(localized: "Timeline · Forward", bundle: AppResources.localizationBundle)
        case .timelineMarkIn: String(localized: "Timeline · Mark in", bundle: AppResources.localizationBundle)
        case .timelineMarkOut: String(localized: "Timeline · Mark out", bundle: AppResources.localizationBundle)
        case .timelinePreviousEdit: String(localized: "Timeline · Previous edit", bundle: AppResources.localizationBundle)
        case .timelineNextEdit: String(localized: "Timeline · Next edit", bundle: AppResources.localizationBundle)
        case .timelineRecord: String(localized: "Timeline · Record", bundle: AppResources.localizationBundle)
        case .timelineRewind: String(localized: "Timeline · Rewind", bundle: AppResources.localizationBundle)
        case .timelineFastForward: String(localized: "Timeline · Fast forward", bundle: AppResources.localizationBundle)
        case .figmaComment: String(localized: "Figma · Comment tool", bundle: AppResources.localizationBundle)
        case .figmaFrame: String(localized: "Figma · Frame tool", bundle: AppResources.localizationBundle)
        case .figmaHand: String(localized: "Figma · Hand tool", bundle: AppResources.localizationBundle)
        case .figmaDevMode: String(localized: "Figma · Dev mode", bundle: AppResources.localizationBundle)
        case .terminalNewTab: String(localized: "Terminal · New tab", bundle: AppResources.localizationBundle)
        case .terminalCloseTab: String(localized: "Terminal · Close tab", bundle: AppResources.localizationBundle)
        case .terminalNextTab: String(localized: "Terminal · Next tab", bundle: AppResources.localizationBundle)
        case .terminalPreviousTab: String(localized: "Terminal · Previous tab", bundle: AppResources.localizationBundle)
        case .terminalClear: String(localized: "Terminal · Clear", bundle: AppResources.localizationBundle)
        case .terminalInterrupt: String(localized: "Terminal · Interrupt", bundle: AppResources.localizationBundle)
        case .terminalSearchHistory: String(localized: "Terminal · Search history", bundle: AppResources.localizationBundle)
        case .terminalSplitPane: String(localized: "Terminal · Split pane", bundle: AppResources.localizationBundle)
        case .terminalClosePane: String(localized: "Terminal · Close pane", bundle: AppResources.localizationBundle)
        case .mouseLeftClick: String(localized: "Mouse · Left click", bundle: AppResources.localizationBundle)
        case .mouseRightClick: String(localized: "Mouse · Right click", bundle: AppResources.localizationBundle)
        case .mouseMiddleClick: String(localized: "Mouse · Middle click", bundle: AppResources.localizationBundle)
        case .screenshotSelection: String(localized: "Screenshot · Select area", bundle: AppResources.localizationBundle)
        case .back: String(localized: "Navigate back", bundle: AppResources.localizationBundle)
        case .forward: String(localized: "Navigate forward", bundle: AppResources.localizationBundle)
        case .missionControl: String(localized: "Mission Control", bundle: AppResources.localizationBundle)
        case .showDesktop: String(localized: "Show desktop", bundle: AppResources.localizationBundle)
        case .appSwitcher: String(localized: "App switcher", bundle: AppResources.localizationBundle)
        case .returnKey: String(localized: "Return", bundle: AppResources.localizationBundle)
        case .escapeKey: String(localized: "Escape", bundle: AppResources.localizationBundle)
        case .spaceKey: String(localized: "Space", bundle: AppResources.localizationBundle)
        case .tabKey: String(localized: "Tab", bundle: AppResources.localizationBundle)
        case .copy: String(localized: "Edit · Copy", bundle: AppResources.localizationBundle)
        case .paste: String(localized: "Edit · Paste", bundle: AppResources.localizationBundle)
        case .cut: String(localized: "Edit · Cut", bundle: AppResources.localizationBundle)
        case .selectAll: String(localized: "Edit · Select all", bundle: AppResources.localizationBundle)
        case .undo: String(localized: "Edit · Undo", bundle: AppResources.localizationBundle)
        case .redo: String(localized: "Edit · Redo", bundle: AppResources.localizationBundle)
        case .zoomIn: String(localized: "View · Zoom in", bundle: AppResources.localizationBundle)
        case .zoomOut: String(localized: "View · Zoom out", bundle: AppResources.localizationBundle)
        case .arrowUp: String(localized: "Arrow up", bundle: AppResources.localizationBundle)
        case .arrowDown: String(localized: "Arrow down", bundle: AppResources.localizationBundle)
        case .arrowLeft: String(localized: "Arrow left", bundle: AppResources.localizationBundle)
        case .arrowRight: String(localized: "Arrow right", bundle: AppResources.localizationBundle)
        case .browserAddress: String(localized: "Browser · Address bar", bundle: AppResources.localizationBundle)
        case .browserNewTab: String(localized: "Browser · New tab", bundle: AppResources.localizationBundle)
        case .browserCloseTab: String(localized: "Browser · Close tab", bundle: AppResources.localizationBundle)
        case .browserReopenTab: String(localized: "Browser · Reopen tab", bundle: AppResources.localizationBundle)
        case .browserReload: String(localized: "Browser · Reload", bundle: AppResources.localizationBundle)
        case .browserFind: String(localized: "Browser · Find", bundle: AppResources.localizationBundle)
        case .browserNextTab: String(localized: "Browser · Next tab", bundle: AppResources.localizationBundle)
        case .browserPreviousTab: String(localized: "Browser · Previous tab", bundle: AppResources.localizationBundle)
        case .mediaPlayPause: String(localized: "Media · Play / pause", bundle: AppResources.localizationBundle)
        case .mediaNext: String(localized: "Media · Next", bundle: AppResources.localizationBundle)
        case .mediaPrevious: String(localized: "Media · Previous", bundle: AppResources.localizationBundle)
        case .volumeUp: String(localized: "Volume up", bundle: AppResources.localizationBundle)
        case .volumeDown: String(localized: "Volume down", bundle: AppResources.localizationBundle)
        case .volumeMute: String(localized: "Mute", bundle: AppResources.localizationBundle)
        case .openCodex: String(localized: "Open Codex", bundle: AppResources.localizationBundle)
        case .openChrome: String(localized: "Open Chrome", bundle: AppResources.localizationBundle)
        case .openSpotify: String(localized: "Open Spotify", bundle: AppResources.localizationBundle)
        case .openClaude: String(localized: "Open Claude", bundle: AppResources.localizationBundle)
        case .cursorDictation: String(localized: "Cursor · Hold to dictate", bundle: AppResources.localizationBundle)
        case .grokDictation: String(localized: "Grok Bot · Hold to dictate", bundle: AppResources.localizationBundle)
        case .systemDictation: String(localized: "Universal dictation", bundle: AppResources.localizationBundle)
        case .showControllerOverlay: String(localized: "Show controller overlay", bundle: AppResources.localizationBundle)
        case .deleteTextWithConfirmation: String(localized: "Text · Delete with confirmation", bundle: AppResources.localizationBundle)
        }
    }

    var category: ActionCategory {
        switch self {
        case .codexSend, .codexStop, .codexReview, .codexPlan, .codexNewTask,
             .codexCommandMenu, .codexFocus, .codexPreviousTask, .codexNextTask,
             .codexBack, .codexForward, .codexSidebar, .codexQuickChat,
             .codexTerminal, .codexApprove, .codexDecline, .codexDictation, .codexAppSnapshot,
             .codexFastMode, .codexContinueInNewTask:
            .codex
        case .claudeNewChat, .claudeSidebar, .claudeCode,
             .claudeProjects:
            .claude
        case .meetingMute, .meetingPushToTalk, .meetingVideo,
             .meetingChat, .meetingParticipants, .meetingShare,
             .meetingRaiseHand:
            .meeting
        case .presentationStart, .presentationNext,
             .presentationPrevious, .presentationBlackScreen,
             .presentationPointer, .presentationNotesUp,
             .presentationNotesDown, .presentationExit:
            .presentation
        case .slackJumpConversation, .slackPreviousUnread,
             .slackNextUnread, .slackThreads, .slackActivity,
             .slackHuddle, .mailArchive, .mailReply, .mailUnread:
            .communication
        case .photosFavorite, .photosEdit, .photosRotate, .photosInfo:
            .files
        case .timelinePlayPause, .timelineReverse, .timelinePause,
             .timelineForward, .timelineMarkIn, .timelineMarkOut,
             .timelinePreviousEdit, .timelineNextEdit, .timelineRecord,
             .timelineRewind, .timelineFastForward, .figmaComment,
             .figmaFrame, .figmaHand, .figmaDevMode:
            .creative
        case .terminalNewTab, .terminalCloseTab, .terminalNextTab,
             .terminalPreviousTab, .terminalClear, .terminalInterrupt,
             .terminalSearchHistory, .terminalSplitPane,
             .terminalClosePane:
            .terminal
        case .mouseLeftClick, .mouseRightClick, .mouseMiddleClick:
            .mouse
        case .back, .forward, .missionControl, .showDesktop, .appSwitcher:
            .navigation
        case .returnKey, .escapeKey, .spaceKey, .tabKey, .copy, .paste, .cut,
             .selectAll, .undo, .redo, .zoomIn, .zoomOut, .arrowUp,
             .arrowDown, .arrowLeft, .arrowRight:
            .keyboard
        case .browserAddress, .browserNewTab, .browserCloseTab, .browserReopenTab,
             .browserReload, .browserFind, .browserNextTab, .browserPreviousTab:
            .browser
        case .mediaPlayPause, .mediaNext, .mediaPrevious, .volumeUp, .volumeDown,
             .volumeMute:
            .media
        case .openCodex, .openChrome, .openSpotify, .openClaude:
            .apps
        case .none, .systemDictation, .cursorDictation, .grokDictation, .screenshotSelection,
             .showControllerOverlay, .deleteTextWithConfirmation:
            .other
        }
    }
}

struct StickPointerSettings: Codable, Equatable, Sendable {
    var source: ControllerStick
    var speed: Double
    var acceleration: Double
    var deadZone: Double
    var scrollSource: ControllerStick
    var scrollSpeed: Double
    var scrollAcceleration: Double
    var scrollDeadZone: Double

    init(
        source: ControllerStick,
        speed: Double,
        acceleration: Double,
        deadZone: Double,
        scrollSource: ControllerStick = .right,
        scrollSpeed: Double = 1_050,
        scrollAcceleration: Double = 1.35,
        scrollDeadZone: Double = 0.18
    ) {
        self.source = source
        self.speed = speed
        self.acceleration = acceleration
        self.deadZone = deadZone
        self.scrollSource = scrollSource
        self.scrollSpeed = scrollSpeed
        self.scrollAcceleration = scrollAcceleration
        self.scrollDeadZone = scrollDeadZone
    }

    private enum CodingKeys: String, CodingKey {
        case source
        case speed
        case acceleration
        case deadZone
        case scrollSource
        case scrollSpeed
        case scrollAcceleration
        case scrollDeadZone
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        source = try values.decode(ControllerStick.self, forKey: .source)
        speed = try values.decode(Double.self, forKey: .speed)
        acceleration = try values.decode(Double.self, forKey: .acceleration)
        deadZone = try values.decode(Double.self, forKey: .deadZone)
        scrollSource = try values.decodeIfPresent(
            ControllerStick.self,
            forKey: .scrollSource
        ) ?? .right
        scrollSpeed = try values.decodeIfPresent(
            Double.self,
            forKey: .scrollSpeed
        ) ?? 1_050
        scrollAcceleration = try values.decodeIfPresent(
            Double.self,
            forKey: .scrollAcceleration
        ) ?? 1.35
        scrollDeadZone = try values.decodeIfPresent(
            Double.self,
            forKey: .scrollDeadZone
        ) ?? 0.18
    }

    static let codexDefault = StickPointerSettings(
        source: .left,
        speed: 820,
        acceleration: 1.7,
        deadZone: 0.17
    )
    static let generalDefault = StickPointerSettings(
        source: .left,
        speed: 900,
        acceleration: 1.65,
        deadZone: 0.16
    )
}

enum TouchpadMotionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case scroll
    case pointer
    case gesturesOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .scroll: String(localized: "Scroll", bundle: AppResources.localizationBundle)
        case .pointer: String(localized: "Pointer", bundle: AppResources.localizationBundle)
        case .gesturesOnly: String(localized: "Gestures", bundle: AppResources.localizationBundle)
        }
    }
}

struct TouchpadSettings: Codable, Equatable, Sendable {
    var oneFingerMode: TouchpadMotionMode
    var twoFingerScroll: Bool
    var naturalScrolling: Bool
    var pointerSensitivity: Double
    var scrollSensitivity: Double
    var gestureBindings: [String: String]

    init(
        oneFingerMode: TouchpadMotionMode,
        twoFingerScroll: Bool,
        pointerSensitivity: Double,
        scrollSensitivity: Double,
        gestureBindings: [String: String],
        naturalScrolling: Bool = true
    ) {
        self.oneFingerMode = oneFingerMode
        self.twoFingerScroll = twoFingerScroll
        self.naturalScrolling = naturalScrolling
        self.pointerSensitivity = pointerSensitivity
        self.scrollSensitivity = scrollSensitivity
        self.gestureBindings = gestureBindings
    }

    private enum CodingKeys: String, CodingKey {
        case oneFingerMode
        case oneFingerPointer
        case twoFingerScroll
        case naturalScrolling
        case pointerSensitivity
        case scrollSensitivity
        case gestureBindings
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let mode = try values.decodeIfPresent(
            TouchpadMotionMode.self,
            forKey: .oneFingerMode
        ) {
            oneFingerMode = mode
        } else {
            let legacyPointer = try values.decodeIfPresent(
                Bool.self,
                forKey: .oneFingerPointer
            ) ?? true
            oneFingerMode = legacyPointer ? .pointer : .scroll
        }
        naturalScrolling = try values.decodeIfPresent(Bool.self, forKey: .naturalScrolling) ?? true
        twoFingerScroll = try values.decode(
            Bool.self,
            forKey: .twoFingerScroll
        )
        pointerSensitivity = try values.decode(
            Double.self,
            forKey: .pointerSensitivity
        )
        scrollSensitivity = try values.decode(
            Double.self,
            forKey: .scrollSensitivity
        )
        gestureBindings = try values.decode(
            [String: String].self,
            forKey: .gestureBindings
        )
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(oneFingerMode, forKey: .oneFingerMode)
        try values.encode(twoFingerScroll, forKey: .twoFingerScroll)
        try values.encode(naturalScrolling, forKey: .naturalScrolling)
        try values.encode(pointerSensitivity, forKey: .pointerSensitivity)
        try values.encode(scrollSensitivity, forKey: .scrollSensitivity)
        try values.encode(gestureBindings, forKey: .gestureBindings)
    }

    func action(for gesture: TouchGesture) -> MappedAction {
        guard let rawValue = gestureBindings[gesture.rawValue] else { return .none }
        return MappedAction(rawValue: rawValue) ?? .none
    }

    mutating func setAction(_ action: MappedAction, for gesture: TouchGesture) {
        gestureBindings[gesture.rawValue] = action.rawValue
    }

    static let trackpadDefault = TouchpadSettings(
        oneFingerMode: .scroll,
        twoFingerScroll: true,
        pointerSensitivity: 1,
        scrollSensitivity: 1,
        gestureBindings: [
            TouchGesture.oneFingerTap.rawValue: MappedAction.mouseLeftClick.rawValue,
            TouchGesture.twoFingerTap.rawValue: MappedAction.mouseRightClick.rawValue,
            TouchGesture.oneFingerLongPress.rawValue: MappedAction.mouseLeftClick.rawValue,
            TouchGesture.twoFingerSwipeLeft.rawValue: MappedAction.back.rawValue,
            TouchGesture.twoFingerSwipeRight.rawValue: MappedAction.forward.rawValue,
            TouchGesture.twoFingerSwipeUp.rawValue: MappedAction.missionControl.rawValue,
            TouchGesture.twoFingerSwipeDown.rawValue: MappedAction.showDesktop.rawValue
        ]
    )
}

enum ProfileKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex
    case cursor
    case grokBot
    case general
    case chrome
    case spotify
    case claude
    case xcode
    case finder
    case meetings
    case presentations
    case slack
    case mail
    case photos
    case figma
    case videoEditing
    case logic
    case terminal

    var id: String { rawValue }

    var label: String {
        switch self {
        case .codex: String(localized: "Codex", bundle: AppResources.localizationBundle)
        case .cursor: String(localized: "Cursor", bundle: AppResources.localizationBundle)
        case .grokBot: String(localized: "Grok Bot", bundle: AppResources.localizationBundle)
        case .general: String(localized: "General", bundle: AppResources.localizationBundle)
        case .chrome: String(localized: "Chrome", bundle: AppResources.localizationBundle)
        case .spotify: String(localized: "Spotify", bundle: AppResources.localizationBundle)
        case .claude: String(localized: "Claude", bundle: AppResources.localizationBundle)
        case .xcode: String(localized: "Xcode", bundle: AppResources.localizationBundle)
        case .finder: String(localized: "Finder", bundle: AppResources.localizationBundle)
        case .meetings: String(localized: "Meetings", bundle: AppResources.localizationBundle)
        case .presentations: String(localized: "Presentations", bundle: AppResources.localizationBundle)
        case .slack: String(localized: "Slack", bundle: AppResources.localizationBundle)
        case .mail: String(localized: "Mail", bundle: AppResources.localizationBundle)
        case .photos: String(localized: "Photos", bundle: AppResources.localizationBundle)
        case .figma: String(localized: "Figma", bundle: AppResources.localizationBundle)
        case .videoEditing: String(localized: "Video Editing", bundle: AppResources.localizationBundle)
        case .logic: String(localized: "Logic Pro", bundle: AppResources.localizationBundle)
        case .terminal: String(localized: "Terminal", bundle: AppResources.localizationBundle)
        }
    }

    var systemImage: String {
        switch self {
        case .codex: "terminal"
        case .cursor: "cursorarrow"
        case .grokBot: "bubble.left.and.bubble.right"
        case .general: "macbook"
        case .chrome: "globe"
        case .spotify: "music.note"
        case .claude: "sparkles"
        case .xcode: "hammer"
        case .finder: "folder"
        case .meetings: "video"
        case .presentations: "play.rectangle"
        case .slack: "number"
        case .mail: "envelope"
        case .photos: "photo.on.rectangle"
        case .figma: "paintbrush.pointed"
        case .videoEditing: "timeline.selection"
        case .logic: "waveform"
        case .terminal: "apple.terminal"
        }
    }
}

struct ControllerProfile: Codable, Equatable, Identifiable, Sendable {
    var kind: ProfileKind
    var name: String

    /// Translate built-in names only. Persisted/exported names and user names stay unchanged.
    var displayName: String {
        guard Self.defaults.first(where: { $0.kind == kind })?.name == name else {
            return name
        }
        return AppResources.localizationBundle.localizedString(forKey: name, value: name, table: nil)
    }
    var bundleIdentifiers: [String]
    var windowTitleKeywords: [String]
    var bindings: [String: String]
    var pointer: StickPointerSettings
    var touchpad: TouchpadSettings
    var gyro: GyroSettings

    var id: String { kind.rawValue }

    init(
        kind: ProfileKind,
        name: String,
        bundleIdentifiers: [String],
        windowTitleKeywords: [String] = [],
        bindings: [String: String],
        pointer: StickPointerSettings,
        touchpad: TouchpadSettings,
        gyro: GyroSettings = .shakeOnly
    ) {
        self.kind = kind
        self.name = name
        self.bundleIdentifiers = bundleIdentifiers
        self.windowTitleKeywords = windowTitleKeywords
        self.bindings = bindings
        self.pointer = pointer
        self.touchpad = touchpad
        self.gyro = gyro
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case name
        case bundleIdentifiers
        case windowTitleKeywords
        case bindings
        case pointer
        case touchpad
        case gyro
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(ProfileKind.self, forKey: .kind)
        name = try values.decode(String.self, forKey: .name)
        bundleIdentifiers = try values.decode(
            [String].self,
            forKey: .bundleIdentifiers
        )
        windowTitleKeywords = try values.decodeIfPresent(
            [String].self,
            forKey: .windowTitleKeywords
        ) ?? []
        bindings = try values.decode([String: String].self, forKey: .bindings)
        pointer = try values.decode(StickPointerSettings.self, forKey: .pointer)
        touchpad = try values.decode(TouchpadSettings.self, forKey: .touchpad)
        gyro = try values.decodeIfPresent(
            GyroSettings.self,
            forKey: .gyro
        ) ?? .shakeOnly
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(kind, forKey: .kind)
        try values.encode(name, forKey: .name)
        try values.encode(bundleIdentifiers, forKey: .bundleIdentifiers)
        try values.encode(windowTitleKeywords, forKey: .windowTitleKeywords)
        try values.encode(bindings, forKey: .bindings)
        try values.encode(pointer, forKey: .pointer)
        try values.encode(touchpad, forKey: .touchpad)
        try values.encode(gyro, forKey: .gyro)
    }

    func action(for input: ControllerInput) -> MappedAction {
        guard let rawValue = bindings[input.rawValue] else { return .none }
        return MappedAction(rawValue: rawValue) ?? .none
    }

    mutating func setAction(_ action: MappedAction, for input: ControllerInput) {
        bindings[input.rawValue] = action.rawValue
    }

    func matches(bundleIdentifier: String?, windowTitle: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        let bundleMatches = bundleIdentifiers.contains { pattern in
            if pattern.hasSuffix("*") {
                return bundleIdentifier.hasPrefix(String(pattern.dropLast()))
            }
            return pattern == bundleIdentifier
        }
        if bundleMatches { return true }
        guard Self.browserBundleIdentifiers.contains(bundleIdentifier),
              let windowTitle,
              !windowTitleKeywords.isEmpty
        else {
            return false
        }
        return windowTitleKeywords.contains {
            windowTitle.localizedCaseInsensitiveContains($0)
        }
    }

    private static let browserBundleIdentifiers: Set<String> = [
        "com.google.Chrome",
        "com.apple.Safari",
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "company.thebrowser.Browser"
    ]

    static var defaults: [ControllerProfile] {
        [
            codex, cursor, grokBot, claude, general, finder, chrome, meetings,
            presentations, slack, mail, photos, spotify, figma,
            videoEditing, logic, terminal, xcode
        ]
    }

    static let codex = ControllerProfile(
        kind: .codex,
        name: "Codex",
        bundleIdentifiers: [
            "com.openai.codex",
            "com.ianhansel.controldeck",
            "com.ianhansel.ps5codex"
        ],
        bindings: mapping([
            .cross: .mouseLeftClick,
            .circle: .codexStop,
            .square: .codexReview,
            .triangle: .codexPlan,
            .l1: .codexPreviousTask,
            .r1: .codexNextTask,
            .l2: .codexDictation,
            .r2: .codexAppSnapshot,
            .l3: .copy,
            .r3: .paste,
            .create: .codexNewTask,
            .options: .codexCommandMenu,
            .ps: .codexFocus,
            .dpadUp: .codexSend,
            .dpadDown: .codexSidebar,
            .dpadLeft: .codexBack,
            .dpadRight: .codexForward,
            .touchpadClick: .showControllerOverlay,
            .microphone: .codexDictation
        ]),
        pointer: .codexDefault,
        touchpad: .trackpadDefault
    )

    static let general = ControllerProfile(
        kind: .general,
        name: "General macOS",
        bundleIdentifiers: [],
        bindings: mapping([
            .cross: .mouseLeftClick,
            .circle: .mouseRightClick,
            .square: .copy,
            .triangle: .paste,
            .l1: .back,
            .r1: .forward,
            .l2: .systemDictation,
            .r2: .codexAppSnapshot,
            .l3: .copy,
            .r3: .paste,
            .create: .systemDictation,
            .options: .escapeKey,
            .ps: .openCodex,
            .dpadUp: .arrowUp,
            .dpadDown: .arrowDown,
            .dpadLeft: .arrowLeft,
            .dpadRight: .arrowRight,
            .touchpadClick: .showControllerOverlay,
            .microphone: .systemDictation
        ]),
        pointer: .generalDefault,
        touchpad: .trackpadDefault
    )

    static let chrome = ControllerProfile(
        kind: .chrome,
        name: "Web browsers",
        bundleIdentifiers: [
            "com.google.Chrome",
            "com.apple.Safari",
            "org.mozilla.firefox",
            "com.microsoft.edgemac",
            "com.brave.Browser",
            "company.thebrowser.Browser"
        ],
        bindings: mapping([
            .cross: .mouseLeftClick,
            .circle: .escapeKey,
            .square: .browserNewTab,
            .triangle: .browserAddress,
            .l1: .back,
            .r1: .forward,
            .l2: .systemDictation,
            .r2: .codexAppSnapshot,
            .l3: .browserFind,
            .r3: .browserReload,
            .create: .browserReopenTab,
            .options: .browserCloseTab,
            .ps: .openCodex,
            .dpadUp: .arrowUp,
            .dpadDown: .arrowDown,
            .dpadLeft: .browserPreviousTab,
            .dpadRight: .browserNextTab,
            .touchpadClick: .showControllerOverlay,
            .microphone: .systemDictation
        ]),
        pointer: .generalDefault,
        touchpad: .trackpadDefault
    )

    static let spotify = ControllerProfile(
        kind: .spotify,
        name: "Music & media",
        bundleIdentifiers: [
            "com.spotify.client",
            "com.apple.Music",
            "org.videolan.vlc"
        ],
        bindings: mapping([
            .cross: .mediaPlayPause,
            .circle: .volumeMute,
            .square: .mediaPrevious,
            .triangle: .mediaNext,
            .l1: .mediaPrevious,
            .r1: .mediaNext,
            .l2: .systemDictation,
            .r2: .codexAppSnapshot,
            .l3: .showDesktop,
            .r3: .missionControl,
            .create: .systemDictation,
            .options: .escapeKey,
            .ps: .openCodex,
            .dpadUp: .volumeUp,
            .dpadDown: .volumeDown,
            .dpadLeft: .mediaPrevious,
            .dpadRight: .mediaNext,
            .touchpadClick: .showControllerOverlay,
            .microphone: .systemDictation
        ]),
        pointer: .generalDefault,
        touchpad: .trackpadDefault
    )

    static let claude = ControllerProfile(
        kind: .claude,
        name: "Claude",
        bundleIdentifiers: [
            "com.anthropic.claudefordesktop",
            "com.anthropic.Claude"
        ],
        bindings: mapping([
            .cross: .mouseLeftClick,
            .circle: .escapeKey,
            .square: .copy,
            .triangle: .claudeCode,
            .l1: .back,
            .r1: .forward,
            .l2: .systemDictation,
            .r2: .codexAppSnapshot,
            .l3: .claudeProjects,
            .r3: .claudeSidebar,
            .create: .claudeNewChat,
            .options: .claudeProjects,
            .ps: .openCodex,
            .dpadUp: .returnKey,
            .dpadDown: .claudeSidebar,
            .dpadLeft: .back,
            .dpadRight: .forward,
            .touchpadClick: .showControllerOverlay,
            .microphone: .systemDictation
        ]),
        pointer: .generalDefault,
        touchpad: .trackpadDefault
    )

    mutating func migrateLegacyCodexSnapshot() {
        guard kind == .codex, action(for: .r2) == .screenshotSelection else { return }
        setAction(.codexAppSnapshot, for: .r2)
    }

    static let cursor = desktopAssistant(
        kind: .cursor, name: "Cursor",
        bundleIdentifier: "com.todesktop.230313mzl4w4u92", dictation: .cursorDictation
    )

    static let grokBot = desktopAssistant(
        kind: .grokBot, name: "Grok Bot",
        bundleIdentifier: "com.anysphere.sand", dictation: .grokDictation
    )

    /// Shared, application-neutral controls avoid invoking Codex-only commands.
    private static func desktopAssistant(
        kind: ProfileKind, name: String, bundleIdentifier: String, dictation: MappedAction
    ) -> ControllerProfile {
        ControllerProfile(
            kind: kind, name: name,
            bundleIdentifiers: [bundleIdentifier],
            bindings: mapping([
                .cross: .mouseLeftClick, .circle: .escapeKey,
                .square: .copy, .triangle: .paste,
                .l1: .back, .r1: .forward,
                .l2: dictation, .r2: .codexAppSnapshot,
                .l3: .copy, .r3: .paste,
                .create: .appSwitcher, .options: .returnKey,
                .ps: .openCodex,
                .dpadUp: .arrowUp, .dpadDown: .arrowDown,
                .dpadLeft: .arrowLeft, .dpadRight: .arrowRight,
                .touchpadClick: .showControllerOverlay,
                .microphone: .systemDictation
            ]),
            pointer: .generalDefault, touchpad: .trackpadDefault
        )
    }

    static let xcode = ControllerProfile(
        kind: .xcode,
        name: "Xcode & editors",
        bundleIdentifiers: [
            "com.apple.dt.Xcode",
            "com.microsoft.VSCode"
        ],
        bindings: mapping([
            .cross: .mouseLeftClick,
            .circle: .escapeKey,
            .square: .browserFind,
            .triangle: .appSwitcher,
            .l1: .back,
            .r1: .forward,
            .l2: .systemDictation,
            .r2: .codexAppSnapshot,
            .l3: .showDesktop,
            .r3: .missionControl,
            .create: .openCodex,
            .options: .browserFind,
            .ps: .openCodex,
            .dpadUp: .arrowUp,
            .dpadDown: .arrowDown,
            .dpadLeft: .arrowLeft,
            .dpadRight: .arrowRight,
            .touchpadClick: .showControllerOverlay,
            .microphone: .systemDictation
        ]),
        pointer: .generalDefault,
        touchpad: .trackpadDefault
    )

    static func mapping(
        _ values: [ControllerInput: MappedAction]
    ) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value.rawValue) }
        )
    }
}
