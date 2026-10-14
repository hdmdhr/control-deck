import AppKit
import ApplicationServices
import Foundation
import OSLog

@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var profiles: [ControllerProfile]
    @Published private(set) var activeKind: ProfileKind
    @Published var editingKind: ProfileKind
    @Published var autoSwitchEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoSwitchEnabled, forKey: autoSwitchKey)
            refreshActiveProfile()
        }
    }

    private let storageKey = "controllerProfiles.v3"
    private let autoSwitchKey = "profileAutoSwitch.v3"
    private let mouseRefinementKey = "mouseRefinement.v1"
    private let interactionLayersKey = "interactionLayers.v1"
    private let expandedProfileCatalogKey = "expandedProfileCatalog.v1"
    private let stickClickCopyPasteKey = "stickClickCopyPaste.v1"
    private let universalL2DictationKey = "universalL2Dictation.v1"
    private let cursorProfileMigrationKey = "cursorProfile.v1"
    private let codexSnapshotKey = "codexAppSnapshot.v1"
    private let universalR2CaptureKey = "universalR2Capture.v1"
    private var activationObserver: NSObjectProtocol?
    private var contextTimer: Timer?
    private var wheelOverrideBundleIdentifier: String?
    private var wheelActivationToken: UUID?
    private var wheelActivationSource: String?
    private var wheelActivationGraceUntil: Date?
    private let logger = Logger(
        subsystem: "com.ianhansel.controldeck",
        category: "profiles"
    )

    init() {
        let defaults = ControllerProfile.defaults
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([ControllerProfile].self, from: data),
           !decoded.isEmpty {
            profiles = ProfileStore.merged(decoded, with: defaults)
        } else {
            profiles = defaults
        }

        let initialKind: ProfileKind = .codex
        activeKind = initialKind
        editingKind = initialKind
        if UserDefaults.standard.object(forKey: autoSwitchKey) == nil {
            autoSwitchEnabled = true
        } else {
            autoSwitchEnabled = UserDefaults.standard.bool(forKey: autoSwitchKey)
        }
        if !UserDefaults.standard.bool(forKey: cursorProfileMigrationKey) {
            // Preserve editor bindings while giving Cursor its dedicated app association.
            if let editor = profiles.firstIndex(where: { $0.kind == .xcode }) {
                profiles[editor].bundleIdentifiers.removeAll {
                    $0 == "com.todesktop.230313mzl4w4u92"
                }
            }
            UserDefaults.standard.set(true, forKey: cursorProfileMigrationKey)
        }
        if !UserDefaults.standard.bool(forKey: mouseRefinementKey) {
            for index in profiles.indices {
                profiles[index].touchpad.oneFingerMode = .scroll
                if profiles[index].kind == .general {
                    if profiles[index].action(for: .square) == .missionControl {
                        profiles[index].setAction(.copy, for: .square)
                    }
                    if profiles[index].action(for: .triangle) == .appSwitcher {
                        profiles[index].setAction(.paste, for: .triangle)
                    }
                }
            }
            UserDefaults.standard.set(true, forKey: mouseRefinementKey)
        }
        if !UserDefaults.standard.bool(forKey: interactionLayersKey) {
            for index in profiles.indices {
                if profiles[index].kind == .codex,
                   profiles[index].action(for: .dpadUp) == .codexPlan {
                    profiles[index].setAction(.codexSend, for: .dpadUp)
                }
                if profiles[index].action(for: .touchpadClick) ==
                    .mouseLeftClick {
                    profiles[index].setAction(
                        .showControllerOverlay,
                        for: .touchpadClick
                    )
                }
            }
            UserDefaults.standard.set(true, forKey: interactionLayersKey)
        }
        if !UserDefaults.standard.bool(forKey: expandedProfileCatalogKey) {
            if let index = profiles.firstIndex(where: { $0.kind == .claude }),
               profiles[index].action(for: .cross) == .returnKey,
               profiles[index].action(for: .create) == .openClaude {
                profiles[index] = .claude
            }
            UserDefaults.standard.set(true, forKey: expandedProfileCatalogKey)
        }
        if !UserDefaults.standard.bool(forKey: stickClickCopyPasteKey) {
            for index in profiles.indices {
                switch profiles[index].kind {
                case .codex:
                    if profiles[index].action(for: .l3) == .codexQuickChat {
                        profiles[index].setAction(.copy, for: .l3)
                    }
                    if profiles[index].action(for: .r3) == .codexTerminal {
                        profiles[index].setAction(.paste, for: .r3)
                    }
                case .general:
                    if profiles[index].action(for: .l3) == .showDesktop {
                        profiles[index].setAction(.copy, for: .l3)
                    }
                    if profiles[index].action(for: .r3) == .missionControl {
                        profiles[index].setAction(.paste, for: .r3)
                    }
                default:
                    break
                }
            }
            UserDefaults.standard.set(true, forKey: stickClickCopyPasteKey)
        }
        if !UserDefaults.standard.bool(forKey: universalL2DictationKey) {
            for index in profiles.indices {
                let previousDefault: MappedAction?
                switch profiles[index].kind {
                case .general:
                    previousDefault = .mouseRightClick
                case .chrome:
                    previousDefault = .browserPreviousTab
                case .spotify:
                    previousDefault = .volumeDown
                case .meetings:
                    previousDefault = .meetingPushToTalk
                case .photos:
                    previousDefault = .zoomOut
                case .figma:
                    previousDefault = .mouseRightClick
                case .videoEditing:
                    previousDefault = .timelineReverse
                default:
                    previousDefault = nil
                }
                if let previousDefault,
                   profiles[index].action(for: .l2) == previousDefault {
                    profiles[index].setAction(.systemDictation, for: .l2)
                }
            }
            UserDefaults.standard.set(true, forKey: universalL2DictationKey)
        }
        if !UserDefaults.standard.bool(forKey: universalR2CaptureKey) {
            let replacedDefaults: [MappedAction] = [
                .mouseLeftClick,
                .browserNextTab,
                .volumeUp,
                .zoomIn,
                .timelineForward,
                .timelineRecord
            ]
            for index in profiles.indices
            where replacedDefaults.contains(profiles[index].action(for: .r2)) {
                profiles[index].setAction(.screenshotSelection, for: .r2)
            }
            UserDefaults.standard.set(true, forKey: universalR2CaptureKey)
        }
        if !UserDefaults.standard.bool(forKey: codexSnapshotKey) {
            for index in profiles.indices {
                profiles[index].migrateLegacyCodexSnapshot()
            }
            UserDefaults.standard.set(true, forKey: codexSnapshotKey)
        }

        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reloadExternalChanges()
                self?.refreshActiveProfile()
            }
        }
        contextTimer = Timer.scheduledTimer(
            withTimeInterval: 1.25,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshActiveProfile()
            }
        }
        refreshActiveProfile()
    }

    deinit {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        contextTimer?.invalidate()
    }

    var activeProfile: ControllerProfile {
        profile(for: activeKind)
    }

    var editingProfile: ControllerProfile {
        profile(for: editingKind)
    }

    func profile(for kind: ProfileKind) -> ControllerProfile {
        profiles.first(where: { $0.kind == kind }) ??
            ControllerProfile.defaults.first ??
            .codex
    }

    func setActiveProfile(_ kind: ProfileKind) {
        guard profiles.contains(where: { $0.kind == kind }) else { return }
        activeKind = kind
        editingKind = kind
        logger.notice("Manual profile selected: \(kind.rawValue)")
    }

    @discardableResult
    func setActiveProfileFromWheel(_ kind: ProfileKind) -> UUID {
        let token = UUID()
        wheelActivationToken = token
        setActiveProfile(kind)
        wheelOverrideBundleIdentifier =
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        logger.notice("Profile wheel selected: \(kind.rawValue)")
        return token
    }

    /// Keep the selected layout while macOS opens/focuses its app, including
    /// intermediate foreground notifications from the window manager.
    func finishWheelActivation(_ token: UUID, targetBundleIdentifier: String? = nil) -> Bool {
        guard wheelActivationToken == token else { return false }
        let foreground = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        wheelActivationSource = foreground
        wheelOverrideBundleIdentifier = targetBundleIdentifier ?? foreground
        wheelActivationGraceUntil = targetBundleIdentifier == nil ? nil : Date().addingTimeInterval(2)
        wheelActivationToken = nil
        return true
    }

    func setAction(_ action: MappedAction, for input: ControllerInput) {
        updateEditingProfile { profile in
            profile.setAction(action, for: input)
        }
    }

    func setGestureAction(_ action: MappedAction, for gesture: TouchGesture) {
        updateEditingProfile { profile in
            profile.touchpad.setAction(action, for: gesture)
        }
    }

    func updatePointerSource(_ source: ControllerStick) {
        updateEditingProfile { $0.pointer.source = source }
    }

    func updatePointerSpeed(_ speed: Double) {
        updateEditingProfile { $0.pointer.speed = speed }
    }

    func updatePointerAcceleration(_ acceleration: Double) {
        updateEditingProfile { $0.pointer.acceleration = acceleration }
    }

    func updateDeadZone(_ deadZone: Double) {
        updateEditingProfile { $0.pointer.deadZone = deadZone }
    }

    func updateScrollSource(_ source: ControllerStick) {
        updateEditingProfile { $0.pointer.scrollSource = source }
    }

    func updateScrollSpeed(_ speed: Double) {
        updateEditingProfile { $0.pointer.scrollSpeed = speed }
    }

    func updateScrollAcceleration(_ acceleration: Double) {
        updateEditingProfile { $0.pointer.scrollAcceleration = acceleration }
    }

    func updateScrollDeadZone(_ deadZone: Double) {
        updateEditingProfile { $0.pointer.scrollDeadZone = deadZone }
    }

    func updateOneFingerMode(_ mode: TouchpadMotionMode) {
        updateEditingProfile { $0.touchpad.oneFingerMode = mode }
    }

    func updateTwoFingerScroll(_ enabled: Bool) {
        updateEditingProfile { $0.touchpad.twoFingerScroll = enabled }
    }

    func updateNaturalScrolling(_ enabled: Bool) {
        updateEditingProfile { $0.touchpad.naturalScrolling = enabled }
    }

    func updateTouchPointerSensitivity(_ value: Double) {
        updateEditingProfile { $0.touchpad.pointerSensitivity = value }
    }

    func updateTouchScrollSensitivity(_ value: Double) {
        updateEditingProfile { $0.touchpad.scrollSensitivity = value }
    }

    func updateGyroEnabled(_ enabled: Bool) {
        updateEditingProfile { $0.gyro.enabled = enabled }
    }

    func updateShakeThreshold(_ value: Double) {
        updateEditingProfile { $0.gyro.shakeThreshold = value }
    }

    func updateTiltThreshold(_ value: Double) {
        updateEditingProfile { $0.gyro.tiltThreshold = value }
    }

    func updateRotationThreshold(_ value: Double) {
        updateEditingProfile { $0.gyro.rotationThreshold = value }
    }

    func setGyroAction(_ action: MappedAction, for gesture: GyroGesture) {
        updateEditingProfile { $0.gyro.setAction(action, for: gesture) }
    }

    func applySuggestedGyroMappings() {
        updateEditingProfile { profile in
            for gesture in GyroGesture.allCases {
                profile.gyro.setAction(gesture.suggestedAction, for: gesture)
            }
        }
    }

    func resetGyroToShakeOnly() {
        updateEditingProfile { $0.gyro = .shakeOnly }
    }

    func resetEditingProfile() {
        guard let original = ControllerProfile.defaults.first(
            where: { $0.kind == editingKind }
        ), let index = profiles.firstIndex(where: { $0.kind == editingKind })
        else { return }
        profiles[index] = original
        persist()
    }

    func importProfile(
        _ importedProfile: ControllerProfile,
        into destination: ProfileKind,
        importName: Bool,
        importAppAssignments: Bool
    ) {
        guard let index = profiles.firstIndex(where: { $0.kind == destination })
        else { return }

        let existing = profiles[index]
        var imported = importedProfile
        imported.kind = destination
        if !importName {
            imported.name = existing.name
        }
        if !importAppAssignments {
            imported.bundleIdentifiers = existing.bundleIdentifiers
            imported.windowTitleKeywords = existing.windowTitleKeywords
        }
        profiles[index] = imported
        editingKind = destination
        persist()
        logger.notice(
            "Imported profile into \(destination.rawValue), app assignments=\(importAppAssignments)"
        )
    }

    func refreshActiveProfile() {
        guard autoSwitchEnabled, wheelActivationToken == nil else {
            return
        }
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let wheelOverrideBundleIdentifier {
            if bundleID == wheelOverrideBundleIdentifier {
                wheelActivationGraceUntil = nil
                return
            }
            if bundleID == wheelActivationSource,
               let graceUntil = wheelActivationGraceUntil, Date() < graceUntil { return }
            self.wheelOverrideBundleIdentifier = nil
        }
        let windowTitle = focusedWindowTitle()
        let contextualMatch = profiles.first { profile in
            guard profile.kind != .general else { return false }
            guard !profile.windowTitleKeywords.isEmpty else { return false }
            return profile.matches(
                bundleIdentifier: bundleID,
                windowTitle: windowTitle
            )
        }
        let applicationMatch = profiles.first { profile in
            guard profile.kind != .general else { return false }
            return profile.matches(
                bundleIdentifier: bundleID,
                windowTitle: nil
            )
        }
        let matched = contextualMatch ?? applicationMatch
        let next = matched?.kind ?? .general
        guard next != activeKind else { return }
        activeKind = next
        logger.notice(
            "Automatic profile: \(next.rawValue), app=\(bundleID ?? "unknown")"
        )
    }

    private func focusedWindowTitle() -> String? {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication
        else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            root,
            kAXFocusedWindowAttribute as CFString,
            &windowValue
        ) == .success,
        let window = windowValue as! AXUIElement?
        else { return nil }
        var titleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window,
            kAXTitleAttribute as CFString,
            &titleValue
        ) == .success
        else { return nil }
        return titleValue as? String
    }

    func reloadExternalChanges() {
        UserDefaults.standard.synchronize()
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(
                  [ControllerProfile].self,
                  from: data
              ),
              !decoded.isEmpty
        else {
            return
        }
        let merged = ProfileStore.merged(
            decoded,
            with: ControllerProfile.defaults
        )
        guard merged != profiles else { return }
        profiles = merged
        if !profiles.contains(where: { $0.kind == editingKind }) {
            editingKind = .codex
        }
        if !profiles.contains(where: { $0.kind == activeKind }) {
            activeKind = .codex
        }
    }

    private func updateEditingProfile(
        _ update: (inout ControllerProfile) -> Void
    ) {
        guard let index = profiles.firstIndex(where: { $0.kind == editingKind })
        else { return }
        update(&profiles[index])
        persist()
        objectWillChange.send()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private static func merged(
        _ saved: [ControllerProfile],
        with defaults: [ControllerProfile]
    ) -> [ControllerProfile] {
        defaults.map { defaultProfile in
            saved.first(where: { $0.kind == defaultProfile.kind }) ?? defaultProfile
        }
    }
}
