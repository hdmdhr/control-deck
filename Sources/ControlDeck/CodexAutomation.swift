import ApplicationServices
import AppKit
import Carbon.HIToolbox
import Foundation

@MainActor
final class CodexAutomation: ObservableObject {
    @Published private(set) var accessibilityTrusted = AXIsProcessTrusted()
    @Published private(set) var lastResult = String(localized: "Ready", bundle: AppResources.localizationBundle)

    private let codexBundleIdentifier = "com.openai.codex"
    private var nativeDictationStarted = false
    private var nativeDictationWindow: AXUIElement?
    private var lastActivatedNativeWindow: AXUIElement?
    private var assistantDictationRelease: CGEvent?
    private var assistantDictationPID: pid_t?
    private var assistantDictationAction: MappedAction?
    private var assistantDictationObserver: NSObjectProtocol?
    private var meetingPushToTalkHeld = false
    private var appSwitcherModifierHeld = false

    private enum MeetingCommand {
        case mute, video, chat, participants, share, raiseHand
    }

    private enum PresentationCommand {
        case start
    }

    func refreshAccessibility() {
        accessibilityTrusted = AXIsProcessTrusted()
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        accessibilityTrusted = AXIsProcessTrustedWithOptions(options)
        if !accessibilityTrusted {
            lastResult = String(localized: "Accessibility permission is required for controller actions", bundle: AppResources.localizationBundle)
        }
    }

    @discardableResult
    func run(_ action: ControllerAction) -> Bool {
        switch action {
        case .sendMessage:
            return key(kVK_Return)
        case .interrupt:
            return key(kVK_Escape)
        case .toggleReview:
            return key(kVK_ANSI_B, flags: [.maskCommand, .maskAlternate])
        case .togglePlan:
            return command(named: "Plan mode")
        case .newTask:
            return key(kVK_ANSI_N, flags: .maskCommand)
        case .commandMenu:
            return key(kVK_ANSI_P, flags: [.maskCommand, .maskShift])
        case .focusCodex:
            return activate()
        case .previousTask:
            return key(kVK_ANSI_LeftBracket, flags: [.maskCommand, .maskShift])
        case .nextTask:
            return key(kVK_ANSI_RightBracket, flags: [.maskCommand, .maskShift])
        case .back:
            return key(kVK_ANSI_LeftBracket, flags: .maskCommand)
        case .forward:
            return key(kVK_ANSI_RightBracket, flags: .maskCommand)
        case .toggleSidebar:
            return key(kVK_ANSI_B, flags: .maskCommand)
        case .quickChat:
            return key(kVK_ANSI_N, flags: [.maskCommand, .maskAlternate])
        case .toggleTerminal:
            return key(kVK_ANSI_Grave, flags: .maskControl)
        case .approve:
            return performSemanticButton(
                exact: ["Approve", "Allow", "Run", "Accept"],
                prefixes: ["Approve ", "Allow ", "Run ", "Accept "]
            )
        case .decline:
            return performSemanticButton(
                exact: ["Decline", "Deny", "Reject"],
                prefixes: ["Decline ", "Deny ", "Reject "]
            )
        case .continueInNewTask:
            return command(named: "Continue in new chat")
        case .toggleFastMode:
            return command(named: "Fast mode")
        case .reasoning:
            return command(named: "Reasoning effort")
        }
    }

    @discardableResult
    func navigateGrokBot(_ action: MappedAction) async -> Bool {
        let result: (succeeded: Bool, message: String)
        switch action {
        case .grokCollapseSection, .grokExpandSection:
            result = await GrokBotNavigation.setCurrentSectionExpanded(action == .grokExpandSection)
        default:
            result = await GrokBotNavigation.navigate(offset: action == .grokPreviousBot ? -1 : 1)
        }
        lastResult = result.message
        return result.succeeded
    }

    @discardableResult
    func navigateCursorConversation(_ action: MappedAction) async -> Bool {
        let result: (succeeded: Bool, message: String)
        switch action {
        case .cursorCollapseWorkspace, .cursorExpandWorkspace:
            result = await CursorConversationNavigation.setCurrentWorkspaceExpanded(action == .cursorExpandWorkspace)
        default:
            result = await CursorConversationNavigation.navigate(offset: action == .cursorPreviousConversation ? -1 : 1)
        }
        lastResult = result.message
        return result.succeeded
    }

    @discardableResult
    func navigateChatGPTSidebar(_ action: MappedAction) async -> Bool {
        let result = await ChatGPTSidebarNavigation.navigate(offset: action == .chatGPTPreviousConversation ? -1 : 1)
        lastResult = result.message
        return result.succeeded
    }

    func run(_ action: MappedAction) -> Bool {
        switch action {
        case .textSelectionHold:
            lastResult = String(localized: "Hold a controller button to select text with the caret stick.", bundle: AppResources.localizationBundle)
            return false
        case .none:
            lastResult = String(localized: "No action assigned", bundle: AppResources.localizationBundle)
            return true
        case .codexSend: return run(.sendMessage)
        case .codexStop: return run(.interrupt)
        case .codexReview: return run(.toggleReview)
        case .codexPlan: return run(.togglePlan)
        case .codexNewTask: return run(.newTask)
        case .codexCommandMenu: return run(.commandMenu)
        case .codexFocus: return run(.focusCodex)
        case .codexPreviousTask: return run(.previousTask)
        case .codexNextTask: return run(.nextTask)
        case .codexBack: return run(ControllerAction.back)
        case .codexForward: return run(ControllerAction.forward)
        case .codexSidebar: return run(.toggleSidebar)
        case .codexQuickChat: return run(.quickChat)
        case .codexTerminal: return run(.toggleTerminal)
        case .codexApprove: return run(.approve)
        case .codexDecline: return run(.decline)
        case .codexDictation: return toggleDictation()
        case .codexAppSnapshot:
            return appSnapshotShortcut()
        case .codexFastMode: return run(.toggleFastMode)
        case .codexContinueInNewTask: return run(.continueInNewTask)

        case .claudeNewChat:
            return key(kVK_ANSI_N, flags: .maskCommand, focusCodex: false)
        case .claudeSidebar:
            return semanticInFrontmostApp(
                exact: ["Open sidebar", "Close sidebar", "Toggle sidebar"]
            )
        case .claudeCode:
            return semanticInFrontmostApp(exact: ["Code"])
        case .claudeProjects:
            return semanticInFrontmostApp(exact: ["Projects"])

        case .meetingMute: return meetingShortcut(.mute)
        case .meetingPushToTalk:
            lastResult = String(localized: "Hold L2 for push to talk", bundle: AppResources.localizationBundle)
            return true
        case .meetingVideo: return meetingShortcut(.video)
        case .meetingChat: return meetingShortcut(.chat)
        case .meetingParticipants: return meetingShortcut(.participants)
        case .meetingShare: return meetingShortcut(.share)
        case .meetingRaiseHand: return meetingShortcut(.raiseHand)

        case .presentationStart: return presentationShortcut(.start)
        case .presentationNext:
            return key(kVK_RightArrow, focusCodex: false)
        case .presentationPrevious:
            return key(kVK_LeftArrow, focusCodex: false)
        case .presentationBlackScreen:
            return key(kVK_ANSI_B, focusCodex: false)
        case .presentationPointer:
            return key(kVK_ANSI_C, focusCodex: false)
        case .presentationNotesUp:
            return key(kVK_ANSI_U, focusCodex: false)
        case .presentationNotesDown:
            return key(kVK_ANSI_D, focusCodex: false)
        case .presentationExit:
            return key(kVK_Escape, focusCodex: false)

        case .slackJumpConversation:
            return key(kVK_ANSI_K, flags: .maskCommand, focusCodex: false)
        case .slackPreviousUnread:
            return key(kVK_UpArrow, flags: [.maskAlternate, .maskShift], focusCodex: false)
        case .slackNextUnread:
            return key(kVK_DownArrow, flags: [.maskAlternate, .maskShift], focusCodex: false)
        case .slackThreads:
            return key(kVK_ANSI_T, flags: [.maskCommand, .maskShift], focusCodex: false)
        case .slackActivity:
            return key(kVK_ANSI_M, flags: [.maskCommand, .maskShift], focusCodex: false)
        case .slackHuddle:
            return key(kVK_ANSI_H, flags: [.maskCommand, .maskShift], focusCodex: false)

        case .mailArchive:
            return key(kVK_ANSI_A, flags: [.maskControl, .maskCommand], focusCodex: false)
        case .mailReply:
            return key(kVK_ANSI_R, flags: .maskCommand, focusCodex: false)
        case .mailUnread:
            return key(kVK_ANSI_U, flags: [.maskCommand, .maskShift], focusCodex: false)

        case .photosFavorite:
            return key(kVK_ANSI_Period, focusCodex: false)
        case .photosEdit:
            return key(kVK_Return, focusCodex: false)
        case .photosRotate:
            return key(kVK_ANSI_R, flags: .maskCommand, focusCodex: false)
        case .photosInfo:
            return key(kVK_ANSI_I, flags: .maskCommand, focusCodex: false)

        case .timelinePlayPause:
            return key(kVK_Space, focusCodex: false)
        case .timelineReverse:
            return key(kVK_ANSI_J, focusCodex: false)
        case .timelinePause:
            return key(kVK_ANSI_K, focusCodex: false)
        case .timelineForward:
            return key(kVK_ANSI_L, focusCodex: false)
        case .timelineMarkIn:
            return key(kVK_ANSI_I, focusCodex: false)
        case .timelineMarkOut:
            return key(kVK_ANSI_O, focusCodex: false)
        case .timelinePreviousEdit:
            return key(kVK_UpArrow, focusCodex: false)
        case .timelineNextEdit:
            return key(kVK_DownArrow, focusCodex: false)
        case .timelineRecord:
            return key(kVK_ANSI_R, focusCodex: false)
        case .timelineRewind:
            return key(kVK_ANSI_Comma, focusCodex: false)
        case .timelineFastForward:
            return key(kVK_ANSI_Period, focusCodex: false)

        case .figmaComment:
            return key(kVK_ANSI_C, focusCodex: false)
        case .figmaFrame:
            return key(kVK_ANSI_F, focusCodex: false)
        case .figmaHand:
            return key(kVK_ANSI_H, focusCodex: false)
        case .figmaDevMode:
            return key(kVK_ANSI_D, flags: .maskShift, focusCodex: false)

        case .terminalNewTab:
            return key(kVK_ANSI_T, flags: .maskCommand, focusCodex: false)
        case .terminalCloseTab:
            return key(kVK_ANSI_W, flags: .maskCommand, focusCodex: false)
        case .terminalNextTab:
            return key(kVK_Tab, flags: .maskControl, focusCodex: false)
        case .terminalPreviousTab:
            return key(kVK_Tab, flags: [.maskControl, .maskShift], focusCodex: false)
        case .terminalClear:
            return key(kVK_ANSI_L, flags: .maskCommand, focusCodex: false)
        case .terminalInterrupt:
            return key(kVK_ANSI_Period, flags: .maskCommand, focusCodex: false)
        case .terminalSearchHistory:
            return key(kVK_ANSI_R, flags: .maskControl, focusCodex: false)
        case .terminalSplitPane:
            return key(kVK_ANSI_D, flags: .maskCommand, focusCodex: false)
        case .terminalClosePane:
            return key(kVK_ANSI_D, flags: [.maskCommand, .maskShift], focusCodex: false)

        case .mouseLeftClick, .mouseRightClick, .mouseMiddleClick,
             .screenshotSelection:
            lastResult = String(localized: "Mouse action", bundle: AppResources.localizationBundle)
            return true
        case .back:
            return key(
                kVK_ANSI_LeftBracket,
                flags: .maskCommand,
                focusCodex: false
            )
        case .forward:
            return key(
                kVK_ANSI_RightBracket,
                flags: .maskCommand,
                focusCodex: false
            )
        case .missionControl:
            return key(
                kVK_UpArrow,
                flags: .maskControl,
                focusCodex: false
            )
        case .showDesktop:
            return key(kVK_F11, focusCodex: false)
        case .appSwitcher:
            return key(kVK_Tab, flags: .maskCommand, focusCodex: false)
        case .returnKey:
            return key(kVK_Return, focusCodex: false)
        case .escapeKey:
            return key(kVK_Escape, focusCodex: false)
        case .spaceKey:
            return key(kVK_Space, focusCodex: false)
        case .tabKey:
            return key(kVK_Tab, focusCodex: false)
        case .copy:
            return key(kVK_ANSI_C, flags: .maskCommand, focusCodex: false)
        case .paste:
            return key(kVK_ANSI_V, flags: .maskCommand, focusCodex: false)
        case .cut:
            return key(kVK_ANSI_X, flags: .maskCommand, focusCodex: false)
        case .selectAll:
            return key(kVK_ANSI_A, flags: .maskCommand, focusCodex: false)
        case .undo:
            return key(kVK_ANSI_Z, flags: .maskCommand, focusCodex: false)
        case .redo:
            return key(kVK_ANSI_Z, flags: [.maskCommand, .maskShift], focusCodex: false)
        case .zoomIn:
            return key(kVK_ANSI_Equal, flags: .maskCommand, focusCodex: false)
        case .zoomOut:
            return key(kVK_ANSI_Minus, flags: .maskCommand, focusCodex: false)
        case .arrowUp:
            return key(kVK_UpArrow, focusCodex: false)
        case .arrowDown:
            return key(kVK_DownArrow, focusCodex: false)
        case .arrowLeft:
            return key(kVK_LeftArrow, focusCodex: false)
        case .arrowRight:
            return key(kVK_RightArrow, focusCodex: false)
        case .browserAddress:
            return key(kVK_ANSI_L, flags: .maskCommand, focusCodex: false)
        case .browserNewTab:
            return key(kVK_ANSI_T, flags: .maskCommand, focusCodex: false)
        case .browserCloseTab:
            return key(kVK_ANSI_W, flags: .maskCommand, focusCodex: false)
        case .browserReopenTab:
            return key(
                kVK_ANSI_T,
                flags: [.maskCommand, .maskShift],
                focusCodex: false
            )
        case .browserReload:
            return key(kVK_ANSI_R, flags: .maskCommand, focusCodex: false)
        case .browserFind:
            return key(kVK_ANSI_F, flags: .maskCommand, focusCodex: false)
        case .browserNextTab:
            return key(
                kVK_RightArrow,
                flags: [.maskCommand, .maskAlternate],
                focusCodex: false
            )
        case .browserPreviousTab:
            return key(
                kVK_LeftArrow,
                flags: [.maskCommand, .maskAlternate],
                focusCodex: false
            )
        case .mediaPlayPause:
            return mediaKey(16)
        case .mediaNext:
            return mediaKey(17)
        case .mediaPrevious:
            return mediaKey(18)
        case .volumeUp:
            return mediaKey(0)
        case .volumeDown:
            return mediaKey(1)
        case .volumeMute:
            return mediaKey(7)
        case .openCodex:
            return activate()
        case .openChrome:
            return activate(
                bundleIdentifier: "com.google.Chrome",
                fallbackPath: "/Applications/Google Chrome.app"
            )
        case .openSpotify:
            return activate(
                bundleIdentifier: "com.spotify.client",
                fallbackPath: "/Applications/Spotify.app"
            )
        case .openClaude:
            return activate(
                bundleIdentifier: "com.anthropic.claudefordesktop",
                fallbackPath: "/Applications/Claude.app"
            )
        case .grokPreviousBot, .grokNextBot, .grokCollapseSection, .grokExpandSection:
            lastResult = "Grok Bot navigation requires asynchronous dispatch"
            return false
        case .chatGPTPreviousConversation, .chatGPTNextConversation:
            lastResult = String(localized: "ChatGPT sidebar navigation requires asynchronous dispatch", bundle: AppResources.localizationBundle)
            return false
        case .cursorPreviousConversation, .cursorNextConversation, .cursorCollapseWorkspace, .cursorExpandWorkspace:
            lastResult = String(localized: "Cursor navigation requires asynchronous dispatch", bundle: AppResources.localizationBundle)
            return false
        case .assistantSend:
            guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                  ["com.todesktop.230313mzl4w4u92", "com.anysphere.sand"].contains(bundleID) else {
                lastResult = String(localized: "Bring Cursor or Grok Bot to the foreground to send", bundle: AppResources.localizationBundle)
                return false
            }
            return key(kVK_Return, focusCodex: false)
        case .assistantRightPanel:
            guard ["com.anysphere.sand", "com.todesktop.230313mzl4w4u92"].contains(frontmostBundleIdentifier ?? "") else {
                lastResult = String(localized: "Bring Cursor or Grok Bot to the foreground first", bundle: AppResources.localizationBundle)
                return false
            }
            return key(kVK_ANSI_B, flags: [.maskCommand, .maskAlternate], focusCodex: false)
        case .cursorDictation, .grokDictation:
            lastResult = String(localized: "Hold the assigned controller button to dictate", bundle: AppResources.localizationBundle)
            return false
        case .systemDictation:
            return toggleSystemDictation()
        case .showControllerOverlay:
            lastResult = String(localized: "Controller overlay", bundle: AppResources.localizationBundle)
            return true
        case .deleteTextWithConfirmation:
            return confirmDeleteFocusedText()
        }
    }

    @discardableResult
    func confirmDeleteFocusedText() -> Bool {
        guard accessibilityTrusted || AXIsProcessTrusted() else {
            requestAccessibility()
            return false
        }
        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
        let focused = focusedValue as! AXUIElement?
        else {
            lastResult = String(localized: "Focus a text field before shaking", bundle: AppResources.localizationBundle)
            return false
        }

        let role = stringAttribute(focused, kAXRoleAttribute)
        let textRoles = [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole]
        guard let role, textRoles.contains(role) else {
            lastResult = String(localized: "Shake to delete only works in a focused text field", bundle: AppResources.localizationBundle)
            return false
        }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            focused,
            kAXValueAttribute as CFString,
            &settable
        ) == .success,
        settable.boolValue
        else {
            lastResult = String(localized: "This text field does not allow safe clearing", bundle: AppResources.localizationBundle)
            return false
        }
        var value: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(
            focused,
            kAXValueAttribute as CFString,
            &value
        )
        guard let text = value as? String, !text.isEmpty else {
            lastResult = String(localized: "The focused text field is already empty", bundle: AppResources.localizationBundle)
            return false
        }

        var processIdentifier: pid_t = 0
        AXUIElementGetPid(focused, &processIdentifier)
        let app = NSRunningApplication(processIdentifier: processIdentifier)
        let appName = app?.localizedName ?? String(localized: "the current app", bundle: AppResources.localizationBundle)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Delete all text?", bundle: AppResources.localizationBundle)
        alert.informativeText =
            String(localized: "This will clear the focused text field in \(appName). The action cannot be undone by ControlDeck.", bundle: AppResources.localizationBundle)
        alert.addButton(withTitle: String(localized: "Delete", bundle: AppResources.localizationBundle))
        alert.addButton(withTitle: String(localized: "Cancel", bundle: AppResources.localizationBundle))
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn else {
            _ = app?.activate(options: [.activateAllWindows])
            lastResult = String(localized: "Delete cancelled", bundle: AppResources.localizationBundle)
            return false
        }
        let result = AXUIElementSetAttributeValue(
            focused,
            kAXValueAttribute as CFString,
            "" as CFString
        )
        _ = app?.activate(options: [.activateAllWindows])
        lastResult = result == .success
            ? String(localized: "Text deleted", bundle: AppResources.localizationBundle)
            : String(localized: "The text field changed before it could be cleared", bundle: AppResources.localizationBundle)
        return result == .success
    }

    @discardableResult
    func runPrompt(_ prompt: String) -> Bool {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            lastResult = String(localized: "This skill slot has no prompt", bundle: AppResources.localizationBundle)
            return false
        }
        guard key(kVK_ANSI_N, flags: .maskCommand) else { return false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            [weak self] in
            self?.type(prompt)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                _ = self?.key(kVK_Return)
            }
        }
        lastResult = String(localized: "Started custom skill", bundle: AppResources.localizationBundle)
        return true
    }

    @discardableResult
    func beginReasoningAdjustment(
        completion: @escaping @MainActor () -> Void
    ) -> Bool {
        guard command(named: "Reasoning effort") else { return false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.52) {
            completion()
        }
        return true
    }

    @discardableResult
    func adjustReasoning(_ step: ReasoningStep) -> Bool {
        key(
            step == .smarter ? kVK_RightArrow : kVK_LeftArrow,
            focusCodex: false
        )
    }

    func finishReasoningAdjustment() {
        _ = key(kVK_Return, focusCodex: false)
    }

    /// Uses only the screenshot-verified native hold shortcuts, and never activates an app.
    @discardableResult
    func beginAssistantDictation(_ action: MappedAction) -> Bool {
        if assistantDictationAction == action { return true }
        endAssistantDictation()
        guard let shortcut = AssistantDictationShortcut.shortcut(for: action) else { return false }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == shortcut.bundleIdentifier else {
            lastResult = String(localized: "Bring the dictation app to the foreground first", bundle: AppResources.localizationBundle)
            return false
        }
        guard accessibilityTrusted || AXIsProcessTrusted() else {
            requestAccessibility()
            return false
        }
        // Allocate the matching release before posting the press. Send both to the
        // captured process so a later focus change cannot type into another app.
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(shortcut.keyCode), keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(shortcut.keyCode), keyDown: false) else {
            lastResult = String(localized: "Unable to create keyboard event", bundle: AppResources.localizationBundle)
            return false
        }
        down.flags = shortcut.flags
        up.flags = shortcut.flags
        assistantDictationRelease = up
        assistantDictationPID = app.processIdentifier
        assistantDictationAction = action
        down.postToPid(app.processIdentifier)
        assistantDictationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier != self.assistantDictationPID else { return }
                self.endAssistantDictation()
            }
        }
        lastResult = action.label
        return true
    }

    func endAssistantDictation() {
        if let up = assistantDictationRelease, let pid = assistantDictationPID {
            up.postToPid(pid)
        }
        assistantDictationRelease = nil
        assistantDictationPID = nil
        assistantDictationAction = nil
        if let observer = assistantDictationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            assistantDictationObserver = nil
        }
    }

    @discardableResult
    func setMeetingPushToTalk(_ active: Bool) -> Bool {
        guard active != meetingPushToTalkHeld else { return true }
        let bundleID = frontmostBundleIdentifier
        let succeeded: Bool
        if bundleID == "us.zoom.xos" {
            succeeded = postKeyState(
                kVK_Space,
                keyDown: active
            )
        } else if bundleID == "com.microsoft.teams2" ||
                    bundleID == "com.microsoft.teams" {
            succeeded = postKeyState(
                kVK_Space,
                flags: .maskAlternate,
                keyDown: active
            )
        } else {
            // Google Meet supports Space as native push to talk when enabled.
            succeeded = postKeyState(kVK_Space, keyDown: active)
        }
        if succeeded {
            meetingPushToTalkHeld = active
            lastResult = active ? String(localized: "Meeting microphone open", bundle: AppResources.localizationBundle) : String(localized: "Meeting microphone muted", bundle: AppResources.localizationBundle)
        }
        return succeeded
    }

    @discardableResult
    func toggleDictation() -> Bool {
        nativeDictationStarted
            ? stopDictationAndInsert()
            : startDictation()
    }

    @discardableResult
    func startDictation() -> Bool {
        // Reconcile with the visible native state after manual interaction. A local
        // flag alone must never report a new capture as successfully started.
        if nativeDictationStarted,
           performNativeCodexButton(exact: CodexDictationIntent.stopAndInsert.exactLabels,
                                    requiredWindow: nativeDictationWindow, press: false) {
            return true
        }
        guard performNativeCodexButton(exact: CodexDictationIntent.start.exactLabels) else { return false }
        nativeDictationStarted = true
        nativeDictationWindow = lastActivatedNativeWindow
        return true
    }

    @discardableResult
    func stopDictationAndInsert() -> Bool {
        guard nativeDictationStarted else { return true }
        guard performNativeCodexButton(exact: CodexDictationIntent.stopAndInsert.exactLabels, requiredWindow: nativeDictationWindow) else { return false }
        nativeDictationStarted = false
        nativeDictationWindow = nil
        return true
    }

    @discardableResult
    func beginAppSwitcher() -> Bool {
        if appSwitcherModifierHeld {
            return advanceAppSwitcher()
        }
        guard postKeyState(
            kVK_Command,
            flags: .maskCommand,
            keyDown: true
        ) else {
            return false
        }
        appSwitcherModifierHeld = true
        guard postAppSwitcherTab(reverse: false) else {
            _ = endAppSwitcher()
            return false
        }
        lastResult = String(localized: "App switcher open", bundle: AppResources.localizationBundle)
        return true
    }

    @discardableResult
    func advanceAppSwitcher() -> Bool {
        guard appSwitcherModifierHeld else {
            return beginAppSwitcher()
        }
        guard postAppSwitcherTab(reverse: false) else { return false }
        lastResult = String(localized: "Next application", bundle: AppResources.localizationBundle)
        return true
    }

    @discardableResult
    func reverseAppSwitcher() -> Bool {
        guard appSwitcherModifierHeld else {
            return beginAppSwitcher()
        }
        guard postAppSwitcherTab(reverse: true) else { return false }
        lastResult = String(localized: "Previous application", bundle: AppResources.localizationBundle)
        return true
    }

    @discardableResult
    func endAppSwitcher() -> Bool {
        guard appSwitcherModifierHeld else { return true }
        let succeeded = postKeyState(kVK_Command, keyDown: false)
        appSwitcherModifierHeld = false
        lastResult = succeeded
            ? String(localized: "Application selected", bundle: AppResources.localizationBundle)
            : String(localized: "Could not close app switcher", bundle: AppResources.localizationBundle)
        return succeeded
    }

    @discardableResult
    func cancelAppSwitcher() -> Bool {
        guard appSwitcherModifierHeld else { return true }
        let escaped = key(
            kVK_Escape,
            flags: .maskCommand,
            focusCodex: false
        )
        let released = postKeyState(kVK_Command, keyDown: false)
        appSwitcherModifierHeld = false
        let succeeded = escaped && released
        lastResult = succeeded
            ? String(localized: "App switcher cancelled", bundle: AppResources.localizationBundle)
            : String(localized: "Could not cancel app switcher", bundle: AppResources.localizationBundle)
        return succeeded
    }

    func openThread(_ id: String) -> Bool {
        guard let url = URL(string: "codex://threads/\(id)") else {
            lastResult = String(localized: "Invalid task identifier", bundle: AppResources.localizationBundle)
            return false
        }
        let result = NSWorkspace.shared.open(url)
        lastResult = result ? String(localized: "Opened task", bundle: AppResources.localizationBundle) : String(localized: "Could not open task", bundle: AppResources.localizationBundle)
        return result
    }

    @discardableResult
    func openSettings() -> Bool {
        guard let url = URL(string: "codex://settings") else {
            lastResult = String(localized: "Could not create the Codex settings link", bundle: AppResources.localizationBundle)
            return false
        }
        let result = NSWorkspace.shared.open(url)
        lastResult = result
            ? String(localized: "Opened Codex settings", bundle: AppResources.localizationBundle)
            : String(localized: "Could not open Codex settings", bundle: AppResources.localizationBundle)
        return result
    }

    private func activate() -> Bool {
        activate(
            bundleIdentifier: codexBundleIdentifier,
            fallbackPath: "/Applications/ChatGPT.app"
        )
    }

    private func activate(
        bundleIdentifier: String,
        fallbackPath: String
    ) -> Bool {
        guard let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).first else {
            NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: fallbackPath),
                configuration: NSWorkspace.OpenConfiguration()
            )
            lastResult = String(localized: "Launching application", bundle: AppResources.localizationBundle)
            return true
        }
        let result = app.activate(options: [.activateAllWindows])
        lastResult = result ? String(localized: "Application focused", bundle: AppResources.localizationBundle) : String(localized: "Could not focus application", bundle: AppResources.localizationBundle)
        return result
    }

    private func appSnapshotShortcut() -> Bool {
        guard accessibilityTrusted || AXIsProcessTrusted() else {
            requestAccessibility()
            return false
        }
        let modifiers: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate, .maskSecondaryFn]
        guard CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty else {
            lastResult = String(localized: "Release keyboard modifiers before taking an app snapshot", bundle: AppResources.localizationBundle)
            return false
        }
        guard let events = AppSnapshotShortcut.events() else {
            lastResult = String(localized: "Unable to create keyboard event", bundle: AppResources.localizationBundle)
            return false
        }
        // Do not activate Codex: its global shortcut captures the foreground app.
        // Post the whole balanced chord together; no delayed release can be cancelled.
        for event in events { event.post(tap: .cghidEventTap) }
        lastResult = String(localized: "Sent app snapshot shortcut", bundle: AppResources.localizationBundle)
        return true
    }

    private func key(
        _ code: Int,
        flags: CGEventFlags = [],
        focusCodex: Bool = true
    ) -> Bool {
        guard accessibilityTrusted || AXIsProcessTrusted() else {
            requestAccessibility()
            return false
        }
        if focusCodex {
            _ = activate()
        }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: false)
        else {
            lastResult = String(localized: "Unable to create keyboard event", bundle: AppResources.localizationBundle)
            return false
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        lastResult = String(localized: "Sent shortcut", bundle: AppResources.localizationBundle)
        return true
    }

    @discardableResult
    func toggleSystemDictation() -> Bool {
        guard key(kVK_Function, focusCodex: false) else { return false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            _ = self?.key(kVK_Function, focusCodex: false)
        }
        lastResult = String(localized: "Universal dictation", bundle: AppResources.localizationBundle)
        return true
    }

    /// Uses Claude's own voice control when the desktop/web surface exposes
    /// one. Claude currently keeps its native Quick Entry dictation behind
    /// app-managed UI, so callers should retain a local transcription fallback.
    @discardableResult
    func startClaudeDictation() -> Bool {
        guard frontmostBundleIdentifier == "com.anthropic.claudefordesktop" ||
                frontmostBundleIdentifier == "com.anthropic.Claude"
        else {
            lastResult = String(localized: "Claude is not the foreground application", bundle: AppResources.localizationBundle)
            return false
        }
        return semanticInFrontmostApp(
            exact: [
                "Start dictation",
                "Start voice input",
                "Voice input",
                "Dictate"
            ]
        )
    }

    @discardableResult
    func stopClaudeDictation() -> Bool {
        guard frontmostBundleIdentifier == "com.anthropic.claudefordesktop" ||
                frontmostBundleIdentifier == "com.anthropic.Claude"
        else {
            lastResult = String(localized: "Claude is not the foreground application", bundle: AppResources.localizationBundle)
            return false
        }
        return semanticInFrontmostApp(
            exact: [
                "Stop dictation",
                "Stop voice input",
                "Stop recording"
            ]
        )
    }

    private func postAppSwitcherTab(reverse: Bool) -> Bool {
        let flags: CGEventFlags = reverse
            ? [.maskCommand, .maskShift]
            : .maskCommand
        return key(kVK_Tab, flags: flags, focusCodex: false)
    }

    private var frontmostBundleIdentifier: String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    private func meetingShortcut(_ command: MeetingCommand) -> Bool {
        let bundleID = frontmostBundleIdentifier
        if bundleID == "us.zoom.xos" {
            let code: Int
            let flags: CGEventFlags
            switch command {
            case .mute: (code, flags) = (kVK_ANSI_A, [.maskCommand, .maskShift])
            case .video: (code, flags) = (kVK_ANSI_V, [.maskCommand, .maskShift])
            case .chat: (code, flags) = (kVK_ANSI_H, [.maskCommand, .maskShift])
            case .participants: (code, flags) = (kVK_ANSI_U, .maskCommand)
            case .share: (code, flags) = (kVK_ANSI_S, [.maskCommand, .maskShift])
            case .raiseHand: (code, flags) = (kVK_ANSI_Y, .maskAlternate)
            }
            return key(code, flags: flags, focusCodex: false)
        }
        if bundleID == "com.microsoft.teams2" ||
            bundleID == "com.microsoft.teams" {
            switch command {
            case .mute:
                return key(kVK_ANSI_M, flags: [.maskCommand, .maskShift], focusCodex: false)
            case .video:
                return key(kVK_ANSI_O, flags: [.maskCommand, .maskShift], focusCodex: false)
            case .share:
                return key(kVK_ANSI_E, flags: [.maskCommand, .maskShift], focusCodex: false)
            case .raiseHand:
                return key(kVK_ANSI_K, flags: [.maskControl, .maskShift], focusCodex: false)
            case .chat:
                return semanticInFrontmostApp(exact: ["Chat", "Show conversation"])
            case .participants:
                return semanticInFrontmostApp(exact: ["People", "Participants", "Show participants"])
            }
        }

        // Browser-hosted Google Meet uses its documented macOS shortcuts.
        switch command {
        case .mute:
            return key(kVK_ANSI_D, flags: .maskCommand, focusCodex: false)
        case .video:
            return key(kVK_ANSI_E, flags: .maskCommand, focusCodex: false)
        case .chat:
            return key(kVK_ANSI_C, flags: [.maskControl, .maskCommand], focusCodex: false)
        case .participants:
            return key(kVK_ANSI_P, flags: [.maskControl, .maskCommand], focusCodex: false)
        case .share:
            return key(kVK_ANSI_T, flags: [.maskControl, .maskCommand], focusCodex: false)
        case .raiseHand:
            return key(kVK_ANSI_H, flags: [.maskControl, .maskCommand], focusCodex: false)
        }
    }

    private func presentationShortcut(_ command: PresentationCommand) -> Bool {
        switch command {
        case .start:
            if frontmostBundleIdentifier == "com.apple.iWork.Keynote" {
                return key(kVK_ANSI_P, flags: [.maskAlternate, .maskCommand], focusCodex: false)
            }
            if frontmostBundleIdentifier == "com.microsoft.Powerpoint" {
                return key(kVK_Return, flags: [.maskCommand, .maskShift], focusCodex: false)
            }
            return key(kVK_Return, flags: [.maskCommand, .maskShift], focusCodex: false)
        }
    }

    private func semanticInFrontmostApp(exact: [String]) -> Bool {
        guard let bundleID = frontmostBundleIdentifier else {
            lastResult = String(localized: "No foreground application", bundle: AppResources.localizationBundle)
            return false
        }
        return performSemanticButton(
            bundleIdentifier: bundleID,
            exact: exact,
            prefixes: exact.map { "\($0) " }
        )
    }

    private func postKeyState(
        _ code: Int,
        flags: CGEventFlags = [],
        keyDown: Bool
    ) -> Bool {
        guard accessibilityTrusted || AXIsProcessTrusted() else {
            requestAccessibility()
            return false
        }
        guard let event = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(code),
            keyDown: keyDown
        ) else {
            lastResult = String(localized: "Unable to create keyboard event", bundle: AppResources.localizationBundle)
            return false
        }
        event.flags = flags
        event.post(tap: .cghidEventTap)
        return true
    }

    private func mediaKey(_ key: Int32) -> Bool {
        guard accessibilityTrusted || AXIsProcessTrusted() else {
            requestAccessibility()
            return false
        }
        let keyDownFlags = NSEvent.ModifierFlags(rawValue: 0xA00)
        let keyUpFlags = NSEvent.ModifierFlags(rawValue: 0xB00)
        let keyDownData = Int((key << 16) | (0xA << 8))
        let keyUpData = Int((key << 16) | (0xB << 8))

        let down = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: keyDownFlags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: keyDownData,
            data2: -1
        )
        let up = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: keyUpFlags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: keyUpData,
            data2: -1
        )
        down?.cgEvent?.post(tap: .cghidEventTap)
        up?.cgEvent?.post(tap: .cghidEventTap)
        lastResult = String(localized: "Sent media key", bundle: AppResources.localizationBundle)
        return down != nil && up != nil
    }

    private func command(named query: String) -> Bool {
        guard key(kVK_ANSI_P, flags: [.maskCommand, .maskShift]) else { return false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            self?.type(query)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                _ = self?.key(kVK_Return)
            }
        }
        lastResult = query
        return true
    }

    private func type(_ text: String) {
        let utf16 = Array(text.utf16)
        for start in stride(from: 0, to: utf16.count, by: 20) {
            let end = min(start + 20, utf16.count)
            let chunk = Array(utf16[start..<end])
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            else { continue }
            chunk.withUnsafeBufferPointer {
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress!)
                up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress!)
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    private func performSemanticButton(
        bundleIdentifier: String? = nil,
        exact: [String],
        prefixes: [String]
    ) -> Bool {
        guard accessibilityTrusted || AXIsProcessTrusted() else {
            requestAccessibility()
            return false
        }
        guard let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier ?? codexBundleIdentifier
        ).first else {
            lastResult = String(localized: "Application is not running", bundle: AppResources.localizationBundle)
            return false
        }

        let root = AXUIElementCreateApplication(app.processIdentifier)
        var focusedWindowValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            root,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowValue
        ) == .success,
        let focusedWindow = focusedWindowValue as! AXUIElement?,
        let match = findButton(
            in: focusedWindow,
            exact: exact,
            prefixes: prefixes,
            depth: 0
        ) {
            let result = AXUIElementPerformAction(
                match,
                kAXPressAction as CFString
            )
            lastResult =
                result == .success ? exact[0] : String(localized: "Could not press \(exact[0])", bundle: AppResources.localizationBundle)
            return result == .success
        }

        if let match = findButton(in: root, exact: exact, prefixes: prefixes, depth: 0) {
            let result = AXUIElementPerformAction(match, kAXPressAction as CFString)
            lastResult = result == .success ? exact[0] : String(localized: "Could not press \(exact[0])", bundle: AppResources.localizationBundle)
            return result == .success
        }

        lastResult = String(localized: "No \(exact[0].lowercased()) request is visible", bundle: AppResources.localizationBundle)
        return false
    }

    /// Only the focused window of the actual Codex bundle is eligible. A unique,
    /// enabled exact semantic match is required; no root-window or shortcut fallback.
    private func performNativeCodexButton(exact: [String], requiredWindow: AXUIElement? = nil, press: Bool = true) -> Bool {
        guard accessibilityTrusted || AXIsProcessTrusted() else {
            requestAccessibility()
            return false
        }
        guard let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: codexBundleIdentifier
        ).first, app.activate(options: [.activateAllWindows]) else {
            lastResult = String(localized: "Application is not running", bundle: AppResources.localizationBundle)
            return false
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var focusedWindowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXFocusedWindowAttribute as CFString, &focusedWindowValue) == .success,
              let value = focusedWindowValue,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            lastResult = String(localized: "Native Codex control is unavailable in the focused window", bundle: AppResources.localizationBundle)
            return false
        }
        let focusedWindow = value as! AXUIElement
        if let requiredWindow, !CFEqual(requiredWindow, focusedWindow) {
            lastResult = String(localized: "Native Codex control is unavailable in the focused window", bundle: AppResources.localizationBundle)
            return false
        }
        var matches: [AXUIElement] = []
        var remaining = 16384
        var visited = Set<AXUIElement>()
        let complete = collectNativeButtons(in: focusedWindow, exact: exact, depth: 0, remaining: &remaining, visited: &visited, matches: &matches)
        let opposingLabels: [String]
        if exact == CodexDictationIntent.start.exactLabels {
            opposingLabels = CodexDictationIntent.stopAndInsert.exactLabels
        } else if exact == CodexDictationIntent.stopAndInsert.exactLabels {
            opposingLabels = CodexDictationIntent.start.exactLabels
        } else {
            opposingLabels = []
        }
        var opposing: [AXUIElement] = []
        var opposingBudget = 16384
        var opposingVisited = Set<AXUIElement>()
        let opposingComplete = opposingLabels.isEmpty || collectNativeButtons(
            in: focusedWindow, exact: opposingLabels, depth: 0,
            remaining: &opposingBudget, visited: &opposingVisited, matches: &opposing
        )
        guard NativeCodexSemanticMatch.isUnique(desiredCount: matches.count,
                                               opposingCount: opposing.count,
                                               traversalComplete: complete && opposingComplete) else {
            if !complete || !opposingComplete {
                lastResult = String(localized: "Dictation search exceeded the window complexity limit", bundle: AppResources.localizationBundle)
            } else if matches.isEmpty {
                lastResult = String(localized: "No accessible dictation button was found in this window", bundle: AppResources.localizationBundle)
            } else {
                lastResult = String(localized: "Multiple or conflicting dictation controls were found", bundle: AppResources.localizationBundle)
            }
            return false
        }
        guard press else { return true }
        let pressed = AXUIElementPerformAction(matches[0], kAXPressAction as CFString) == .success
        if pressed { lastActivatedNativeWindow = focusedWindow }
        lastResult = pressed
            ? String(localized: "Native Codex control activated", bundle: AppResources.localizationBundle)
            : String(localized: "Could not activate native Codex control", bundle: AppResources.localizationBundle)
        return pressed
    }

    private func collectNativeButtons(
        in element: AXUIElement, exact: [String], depth: Int,
        remaining: inout Int, visited: inout Set<AXUIElement>, matches: inout [AXUIElement]
    ) -> Bool {
        guard visited.insert(element).inserted else { return true }
        guard depth < 64, remaining > 0 else { return false }
        remaining -= 1
        if stringAttribute(element, kAXRoleAttribute) == kAXButtonRole {
            var enabled: CFTypeRef?
            let enabledResult = AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabled)
            let labels = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
                .compactMap { stringAttribute(element, $0)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            var actions: CFArray?
            let actionsResult = AXUIElementCopyActionNames(element, &actions)
            if NativeCodexSemanticMatch.matches(
                labels: labels, exact: exact, isButton: true,
                enabled: enabledResult == .success && (enabled as? Bool) == true,
                pressable: actionsResult == .success && (actions as? [String])?.contains(kAXPressAction) == true
            ) {
                matches.append(element)
            }
        }
        var childrenValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue)
        if result == .noValue || result == .attributeUnsupported { return true }
        // Unreadable leaves must not discard valid sibling controls. Bounds still
        // fail closed, and every reachable eligible button participates in uniqueness.
        guard result == .success, let children = childrenValue as? [AXUIElement] else { return true }
        for child in children {
            guard collectNativeButtons(in: child, exact: exact, depth: depth + 1, remaining: &remaining, visited: &visited, matches: &matches) else { return false }
        }
        return true
    }

    private func findButton(
        in element: AXUIElement,
        exact: [String],
        prefixes: [String],
        depth: Int
    ) -> AXUIElement? {
        guard depth < 24 else { return nil }

        var roleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        let role = roleValue as? String

        if role == kAXButtonRole {
            let candidates = [
                stringAttribute(element, kAXTitleAttribute),
                stringAttribute(element, kAXDescriptionAttribute),
                stringAttribute(element, kAXHelpAttribute),
                stringAttribute(element, "AXIdentifier")
            ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }

            if candidates.contains(where: { value in
                exact.contains(where: { value.caseInsensitiveCompare($0) == .orderedSame }) ||
                    prefixes.contains(where: { value.lowercased().hasPrefix($0.lowercased()) })
            }) {
                return element
            }
        }

        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &childrenValue
        ) == .success,
        let children = childrenValue as? [AXUIElement]
        else { return nil }

        for child in children {
            if let result = findButton(in: child, exact: exact, prefixes: prefixes, depth: depth + 1) {
                return result
            }
        }
        return nil
    }

    private func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }
}
