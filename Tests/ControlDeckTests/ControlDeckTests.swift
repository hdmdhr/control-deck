import AppKit
import Foundation

@main
struct ControlDeckLogicTestRunner {
    @MainActor
    static func main() {
        var checks = 0

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            guard condition() else {
                FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
                exit(1)
            }
        }

        func expectThrows(
            _ operation: () throws -> Void,
            _ message: String
        ) {
            checks += 1
            do {
                try operation()
                FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
                exit(1)
            } catch {
                // The rejection is the expected result.
            }
        }

        expect(
            ControllerProfile.codex.action(for: .cross) == .mouseLeftClick,
            "Codex Cross left-clicks"
        )
        expect(
            GeneralDictationEngine.allCases.map(\.label) == [
                "System",
                "Live",
                "Balanced",
                "High Accuracy"
            ] &&
                GeneralDictationEngine.whisperKitSmallEnglish.isWhisperKit,
            "dictation modes expose system, live, balanced and high-accuracy choices"
        )
        expect(
            ControllerProfile.codex.action(for: .l2) == .codexDictation,
            "Codex L2 dictates"
        )
        expect(
            ControllerProfile.defaults
                .filter { ![.codex, .cursor, .grokBot].contains($0.kind) }
                .allSatisfy { $0.action(for: .l2) == .systemDictation },
            "L2 provides universal dictation outside native assistant profiles"
        )
        expect(
            ControllerProfile.codex.action(for: .l3) == .copy &&
                ControllerProfile.codex.action(for: .r3) == .paste,
            "Codex stick clicks copy and paste"
        )
        expect(
            ControllerProfile.general.action(for: .cross) == .mouseLeftClick,
            "General Cross clicks"
        )
        expect(
            ControllerProfile.defaults.allSatisfy {
                $0.action(for: .r2) == .codexAppSnapshot
            },
            "Every profile uses the global app snapshot shortcut on R2"
        )
        var legacyCodexCapture = ControllerProfile.codex
        legacyCodexCapture.setAction(.screenshotSelection, for: .r2)
        legacyCodexCapture.migrateLegacyCodexSnapshot()
        expect(legacyCodexCapture.action(for: .r2) == .codexAppSnapshot,
               "legacy Codex R2 capture upgrades to app snapshot")
        legacyCodexCapture.setAction(.copy, for: .r2)
        legacyCodexCapture.migrateLegacyCodexSnapshot()
        expect(legacyCodexCapture.action(for: .r2) == .copy,
               "Codex R2 migration preserves custom actions")
        expect(CodexDictationIntent.start.matches([" dictation "]) &&
               !CodexDictationIntent.start.matches(["Start voice mode", "Send", "Dictation settings"]),
               "dictation tolerates exact-label casing and whitespace without matching unrelated controls")
        expect(ControllerProfile.cursor.action(for: .l2) == .cursorDictation &&
               ControllerProfile.grokBot.action(for: .l2) == .grokDictation,
               "Cursor and Grok use their native hold-to-dictate actions")
        let cursorShortcut = AssistantDictationShortcut.shortcut(for: .cursorDictation)
        let grokShortcut = AssistantDictationShortcut.shortcut(for: .grokDictation)
        expect(cursorShortcut?.bundleIdentifier == "com.todesktop.230313mzl4w4u92" &&
               cursorShortcut?.keyCode == 46 && cursorShortcut?.flags == .maskControl,
               "Cursor native dictation is Control M for the Cursor process")
        expect(grokShortcut?.bundleIdentifier == "com.anysphere.sand" &&
               grokShortcut?.keyCode == 2 && grokShortcut?.flags == .maskCommand &&
               AssistantDictationShortcut.shortcut(for: .codexSend) == nil,
               "Grok native dictation is Command D and unrelated actions have no shortcut")
        let snapshotEvents = AppSnapshotShortcut.events() ?? []
        expect(snapshotEvents.count == 4 && snapshotEvents.allSatisfy { $0.type == .flagsChanged },
               "app snapshot uses four modifier transitions")
        expect(snapshotEvents.map { $0.getIntegerValueField(.keyboardEventKeycode) } == [55, 54, 54, 55],
               "app snapshot presses left then right Command and releases in reverse order")
        expect(snapshotEvents.map { $0.flags.rawValue } == [0x100008, 0x100018, 0x100008, 0],
               "app snapshot overlaps both Command sides and leaves no synthetic modifier held")
        var appSwitcherHold = AppSwitcherHoldGate()
        let deferredTouchpad = appSwitcherHold.handle(
            .touchpadClick,
            pressed: true
        )
        expect(
            deferredTouchpad == .deferTouchpadTap(generation: 1) &&
                appSwitcherHold.activate(generation: 1) &&
                appSwitcherHold.isActive &&
                appSwitcherHold.handle(.dpadRight, pressed: true) == .forward &&
                appSwitcherHold.handle(.dpadLeft, pressed: true) == .backward &&
                appSwitcherHold.handle(.touchpadClick, pressed: false) == .select &&
                !appSwitcherHold.isActive,
            "holding the touchpad opens, navigates and selects the app switcher"
        )
        var touchpadTapGate = AppSwitcherHoldGate()
        let touchpadTap = touchpadTapGate.handle(
            .touchpadClick,
            pressed: true
        )
        expect(
            touchpadTap == .deferTouchpadTap(generation: 1) &&
                touchpadTapGate.handle(.touchpadClick, pressed: false) ==
                    .performTouchpadTap &&
                !touchpadTapGate.activate(generation: 1),
            "a quick touchpad click keeps its normal overlay action"
        )
        var cancelSwitcherGate = AppSwitcherHoldGate()
        let cancelTouchpad = cancelSwitcherGate.handle(
            .touchpadClick,
            pressed: true
        )
        expect(
            cancelTouchpad == .deferTouchpadTap(generation: 1) &&
                cancelSwitcherGate.activate(generation: 1) &&
                cancelSwitcherGate.handle(.circle, pressed: true) == .cancel &&
                cancelSwitcherGate.handle(.touchpadClick, pressed: false) ==
                    .consume &&
                !cancelSwitcherGate.isActive,
            "Circle cancels the held-touchpad app switcher without showing the overlay"
        )
        var appSwitcherStick = AppSwitcherStickGate()
        expect(
            appSwitcherStick.update(x: 0.75) == .forward &&
                appSwitcherStick.update(x: 0.9) == nil &&
                appSwitcherStick.update(x: 0.1) == nil &&
                appSwitcherStick.update(x: -0.8) == .backward,
            "right-stick app switching steps once per deliberate tilt"
        )
        expect(
            ControllerProfile.codex.gyro.action(for: .shake) ==
                .deleteTextWithConfirmation &&
                ControllerProfile.codex.gyro.action(for: .tiltLeft) == .none,
            "only hard shake has a default gyro action"
        )
        expect(
            GyroSettings.suggested.action(for: .tiltLeft) == .back &&
                GyroSettings.suggested.action(for: .twistClockwise) ==
                    .browserNextTab,
            "optional gyro suggestions use intuitive navigation actions"
        )

        func motion(
            time: Double,
            gravityX: Double = 0,
            accelerationX: Double = 0
        ) -> ControllerMotionSample {
            ControllerMotionSample(
                gravityX: gravityX,
                gravityY: 0,
                gravityZ: -1,
                accelerationX: accelerationX,
                accelerationY: 0,
                accelerationZ: 0,
                rotationX: 0,
                rotationY: 0,
                rotationZ: 0,
                timestamp: time
            )
        }
        var shakeEngine = GyroGestureEngine()
        expect(
            shakeEngine.update(
                motion(time: 0.1, accelerationX: 2.6),
                settings: .shakeOnly
            ) == nil &&
                shakeEngine.update(
                    motion(time: 0.2),
                    settings: .shakeOnly
                ) == nil &&
                shakeEngine.update(
                    motion(time: 0.3, accelerationX: -2.7),
                    settings: .shakeOnly
                ) == nil &&
                shakeEngine.update(
                    motion(time: 0.4),
                    settings: .shakeOnly
                ) == nil &&
                shakeEngine.update(
                    motion(time: 0.5, accelerationX: 2.8),
                    settings: .shakeOnly
                ) == .shake,
            "shake requires three strong alternating impulses"
        )
        var tiltEngine = GyroGestureEngine()
        expect(
            tiltEngine.update(
                motion(time: 1.0, gravityX: -0.75),
                settings: .suggested
            ) == nil &&
                tiltEngine.update(
                    motion(time: 1.35, gravityX: -0.75),
                    settings: .suggested
                ) == .tiltLeft,
            "tilt gestures require an intentional hold"
        )
        var telemetryLimiter = TelemetryRateLimiter(
            minimumInterval: 1.0 / 30.0
        )
        expect(
            telemetryLimiter.shouldPublish(at: 10) &&
                !telemetryLimiter.shouldPublish(at: 10.01) &&
                telemetryLimiter.shouldPublish(at: 10.04),
            "gyro UI telemetry is capped at thirty updates per second"
        )
        var motionForwarding = MotionSampleForwardingGate()
        expect(
            motionForwarding.shouldForward(x: 0, y: 0) &&
                !motionForwarding.shouldForward(x: 0.001, y: 0.001) &&
                motionForwarding.shouldForward(x: 0.01, y: 0),
            "gyro game forwards its first sample and meaningful changes"
        )
        motionForwarding.reset()
        expect(
            motionForwarding.shouldForward(x: 0.01, y: 0),
            "gyro game resends motion after its WebKit bridge reloads"
        )
        func rawMotion(
            time: Double,
            gravityX: Double = 0,
            gravityY: Double = 0,
            gravityZ: Double = 0,
            userAccelerationX: Double = 0,
            totalAccelerationX: Double = 0,
            totalAccelerationY: Double = 0,
            totalAccelerationZ: Double = -1,
            hasSeparateGravity: Bool = false
        ) -> RawControllerMotionSample {
            RawControllerMotionSample(
                reportedGravityX: gravityX,
                reportedGravityY: gravityY,
                reportedGravityZ: gravityZ,
                reportedUserAccelerationX: userAccelerationX,
                reportedUserAccelerationY: 0,
                reportedUserAccelerationZ: 0,
                totalAccelerationX: totalAccelerationX,
                totalAccelerationY: totalAccelerationY,
                totalAccelerationZ: totalAccelerationZ,
                rotationX: 0,
                rotationY: 0,
                rotationZ: 0,
                hasSeparateGravity: hasSeparateGravity,
                timestamp: time
            )
        }
        var fallbackMotion = ControllerMotionNormalizer()
        let stationaryMotion = fallbackMotion.normalize(
            rawMotion(time: 20)
        )
        expect(
            abs(stationaryMotion.gravityZ + 1) < 0.001 &&
                abs(stationaryMotion.accelerationZ) < 0.001,
            "total acceleration initializes the fallback gravity estimate"
        )
        var tiltedMotion = stationaryMotion
        for index in 1...30 {
            tiltedMotion = fallbackMotion.normalize(
                rawMotion(
                    time: 20 + Double(index) * 0.02,
                    totalAccelerationX: 0.72,
                    totalAccelerationZ: -0.69
                )
            )
        }
        expect(
            tiltedMotion.gravityX > 0.65,
            "fallback gravity follows a held tilt for telemetry and the game"
        )
        let impulseMotion = fallbackMotion.normalize(
            rawMotion(
                time: 20.62,
                totalAccelerationX: 3.5,
                totalAccelerationZ: -0.69
            )
        )
        expect(
            impulseMotion.accelerationX > 2.25,
            "fallback filtering preserves strong shake impulses"
        )
        var separatedMotion = ControllerMotionNormalizer()
        let nativeMotion = separatedMotion.normalize(
            rawMotion(
                time: 30,
                gravityX: -0.8,
                gravityZ: -0.6,
                userAccelerationX: 0.35,
                hasSeparateGravity: true
            )
        )
        expect(
            nativeMotion.gravityX == -0.8 &&
                nativeMotion.accelerationX == 0.35,
            "native separated gravity remains authoritative when available"
        )
        expect(
            ControllerProfile.chrome.action(for: .triangle) == .browserAddress,
            "Chrome Triangle focuses address"
        )
        expect(
            ControllerProfile.chrome.action(for: .cross) == .mouseLeftClick,
            "Chrome Cross performs a native left click"
        )
        expect(
            ControllerProfile.spotify.action(for: .cross) == .mediaPlayPause,
            "Spotify Cross controls playback"
        )
        expect(
            ControllerProfile.defaults.count == 18,
            "ControlDeck has eighteen curated app profiles"
        )
        expect(
            ControllerProfile.codex.pointer.source == .left,
            "Codex pointer uses left stick"
        )
        expect(
            ControllerProfile.codex.action(for: .r2)
                == .codexAppSnapshot,
            "Codex R2 captures the Codex app"
        )
        let captureDefaultsName = "ControlDeckTests.ScreenCapture"
        let captureDefaults = UserDefaults(suiteName: captureDefaultsName)!
        captureDefaults.removePersistentDomain(forName: captureDefaultsName)
        let capturePreferences = ScreenCapturePreferences(
            defaults: captureDefaults
        )
        expect(
            capturePreferences.copyOriginalToClipboard &&
                capturePreferences.openEditorAfterCapture &&
                capturePreferences.copyEditedImageOnDone &&
                capturePreferences.defaultTool == .highlighter,
            "screen captures copy and open with the highlighter by default"
        )
        let fittedCapture = ScreenshotCanvasGeometry.aspectFit(
            imageSize: CGSize(width: 1_600, height: 900),
            in: CGRect(x: 0, y: 0, width: 800, height: 800)
        )
        expect(
            fittedCapture == CGRect(x: 0, y: 175, width: 800, height: 450),
            "screenshot editor preserves the captured image aspect ratio"
        )
        let editorModel = ScreenshotEditorModel(
            image: NSImage(size: NSSize(width: 100, height: 100)),
            preferences: capturePreferences
        )
        editorModel.selectAdjacentTool(offset: -1)
        expect(
            editorModel.tool == .redact,
            "controller tool selection wraps in both directions"
        )
        editorModel.tool = .rectangle
        editorModel.begin(at: CGPoint(x: 0.1, y: 0.1))
        editorModel.finish(at: CGPoint(x: 0.8, y: 0.8))
        expect(
            editorModel.canUndo && editorModel.annotations.count == 1,
            "screenshot annotations are recorded and undoable"
        )
        expect(
            editorModel.renderedImage() != nil,
            "screenshot annotations render into an exportable image"
        )
        captureDefaults.removePersistentDomain(forName: captureDefaultsName)
        expect(
            ControllerProfile.codex.action(for: .dpadUp) == .codexSend,
            "Codex D-pad Up sends instead of duplicating Plan"
        )
        expect(
            ControllerProfile.codex.action(for: .touchpadClick) ==
                .showControllerOverlay,
            "Touchpad click shows the contextual controller overlay"
        )
        expect(
            ControllerProfile.codex.action(for: .triangle) == .codexPlan,
            "Triangle remains the single default Plan assignment"
        )
        expect(
            ControllerProfile.claude.action(for: .cross) == .mouseLeftClick &&
                ControllerProfile.claude.action(for: .create) == .claudeNewChat,
            "Claude mirrors Codex's pointer-first flow with native new chat"
        )
        expect(
            ControllerProfile.terminal.action(for: .l2) == .systemDictation &&
                ControllerProfile.terminal.action(for: .create) == .terminalNewTab &&
                ControllerProfile.terminal.action(for: .r3) == .terminalClear,
            "Terminal provides dictation, tab creation and clear-screen controls"
        )
        expect(
            ControllerProfile.meetings.action(for: .l2) == .systemDictation &&
                ControllerProfile.meetings.action(for: .r3) == .meetingVideo,
            "Meetings provide universal dictation and camera controls"
        )
        expect(
            ControllerProfile.videoEditing.action(for: .l2) == .systemDictation &&
                ControllerProfile.videoEditing.action(for: .r2) ==
                    .codexAppSnapshot,
            "Video editors keep universal dictation and reliable R2 capture"
        )
        expect(
            ControllerProfile.meetings.matches(
                bundleIdentifier: "com.google.Chrome",
                windowTitle: "Weekly sync — Google Meet"
            ),
            "browser window context selects the Meetings profile"
        )
        expect(
            ControllerProfile.videoEditing.matches(
                bundleIdentifier: "com.adobe.PremierePro.26",
                windowTitle: nil
            ),
            "wildcard bundle identifiers match versioned creative apps"
        )
        var legacyProfileObject = try! JSONSerialization.jsonObject(
            with: JSONEncoder().encode(ControllerProfile.terminal)
        ) as! [String: Any]
        legacyProfileObject.removeValue(forKey: "windowTitleKeywords")
        legacyProfileObject.removeValue(forKey: "gyro")
        let legacyProfile = try! JSONDecoder().decode(
            ControllerProfile.self,
            from: JSONSerialization.data(withJSONObject: legacyProfileObject)
        )
        expect(
            legacyProfile.windowTitleKeywords.isEmpty &&
                legacyProfile.gyro.action(for: .shake) ==
                    .deleteTextWithConfirmation,
            "legacy profiles gain the safe shake-only gyro default"
        )
        expect(
            ControllerProfile.chrome.bundleIdentifiers.contains(
                "com.apple.Safari"
            ),
            "browser profile includes Safari"
        )
        expect(
            SoundTheme.playful.tones(for: .complete).count == 3,
            "playful completion sound is a short three-note cue"
        )
        expect(
            SoundTheme.off.tones(for: .complete).isEmpty,
            "off sound theme is silent"
        )
        expect(
            ControllerFamily.identify(
                vendorName: "8BitDo Pro 2",
                productCategory: "MFi"
            ) == .eightBitDo,
            "8BitDo controller identification"
        )
        expect(
            ControllerFamily.identify(
                vendorName: "Nintendo Switch 2 Pro Controller",
                productCategory: "Switch"
            ) == .switchPro2,
            "Switch 2 controller identification"
        )
        expect(
            CodexDictationIntent.start.matches(["听写"]) &&
                !CodexDictationIntent.start.matches(["Start voice mode", "Send", "听写设置"]),
            "dictation start only accepts exact native dictation controls"
        )
        expect(
            CodexDictationIntent.stopAndInsert.matches(["停止听写"]) &&
                !CodexDictationIntent.stopAndInsert.matches(["听写"]),
            "dictation stop only accepts the native stop control"
        )
        for eligibility in [(false, true, true), (true, false, true), (true, true, false)] {
            expect(!NativeCodexSemanticMatch.matches(
                labels: ["听写"], exact: CodexDictationIntent.start.exactLabels,
                isButton: eligibility.0, enabled: eligibility.1, pressable: eligibility.2
            ), "native dictation rejects ineligible controls")
        }
        expect(NativeCodexSemanticMatch.isUnique(desiredCount: 1, opposingCount: 0, traversalComplete: true),
               "one verified native control is actionable")
        for counts in [(0, 0, true), (2, 0, true), (1, 1, true), (1, 0, false)] {
            expect(!NativeCodexSemanticMatch.isUnique(
                desiredCount: counts.0, opposingCount: counts.1, traversalComplete: counts.2
            ), "missing, ambiguous, opposing or incomplete native controls fail closed")
        }
        expect(
            ControllerProfile.general.pointer.source == .left,
            "General pointer uses left stick"
        )
        expect(
            ControllerProfile.general.pointer.scrollSource == .right,
            "General scrolling uses right stick"
        )
        expect(
            TouchpadSettings.trackpadDefault.oneFingerMode == .scroll,
            "Touchpad defaults to one-finger scrolling"
        )
        expect(
            ControllerProfile.general.action(for: .square) == .copy &&
                ControllerProfile.general.action(for: .triangle) == .paste,
            "General face buttons provide copy and paste"
        )
        expect(
            ControllerProfile.general.action(for: .l3) == .copy &&
                ControllerProfile.general.action(for: .r3) == .paste,
            "General stick clicks copy and paste"
        )
        expect(
            ProfileWheelSlot.defaults.count == 8 &&
                Set(ProfileWheelSlot.defaults.map(\.position)).count == 8 &&
                Set(ProfileWheelSlot.defaults.map(\.profileKind)).count == 8,
            "Options layer has eight unique popular-app profile slots"
        )
        for fingers in [1, 2] {
            func scrollSample(natural: Bool) -> CGPoint {
                let engine = TouchpadGestureEngine()
                engine.settings.naturalScrolling = natural
                var sample = CGPoint.zero
                engine.onScrollDelta = { sample = CGPoint(x: $0, y: $1) }
                engine.update(finger: .primary, x: 0, y: 0, active: true)
                if fingers == 2 {
                    engine.update(finger: .secondary, x: 0, y: 0, active: true)
                }
                engine.update(finger: .primary, x: 0.1, y: 0.1, active: true)
                engine.cancel()
                return sample
            }
            let natural = scrollSample(natural: true)
            let traditional = scrollSample(natural: false)
            expect(natural.x > 0 && natural.y < 0,
                   "Natural scroll follows both finger axes for \(fingers) fingers")
            expect(natural.x == -traditional.x && natural.y == -traditional.y,
                   "Scroll direction can be reversed for \(fingers) fingers")
        }
        var reversedProfile = ControllerProfile.general
        reversedProfile.touchpad.naturalScrolling = false
        let directionData = try! ProfileTransfer.encode(profile: reversedProfile)
        let directionProfile = try! ProfileTransfer.decode(directionData)
        expect(!directionProfile.profile.touchpad.naturalScrolling,
               "Non-natural scrolling survives profile export and import")
        let tutorialDefaultsName = "ControlDeckTests.QuickTutorial"
        let tutorialDefaults = UserDefaults(suiteName: tutorialDefaultsName)!
        tutorialDefaults.removePersistentDomain(forName: tutorialDefaultsName)
        let tutorial = QuickTutorialStore(defaults: tutorialDefaults)
        tutorial.offerIfNeeded()
        expect(
            tutorial.isPresented && !tutorial.hasBeenOffered &&
                tutorial.currentStep == .welcome,
            "first-run onboarding opens from its welcome step"
        )
        expect(
            tutorial.handleControllerButton(.r1) == .changedStep &&
                tutorial.currentStep == .pairController &&
                tutorial.handleControllerButton(.l1) == .changedStep &&
                tutorial.currentStep == .welcome,
            "controller shoulder buttons navigate the tutorial"
        )
        expect(
            tutorial.handleControllerButton(.circle) == .skipped &&
                !tutorial.isPresented && !tutorial.hasCompleted,
            "Circle skips the tutorial without marking it complete"
        )
        tutorial.start()
        for _ in 0..<tutorial.stepCount {
            _ = tutorial.next()
        }
        let reloadedTutorial = QuickTutorialStore(defaults: tutorialDefaults)
        expect(
            tutorial.hasCompleted && !tutorial.isPresented &&
                reloadedTutorial.hasCompleted,
            "tutorial completion persists and suppresses future offers"
        )
        tutorialDefaults.removePersistentDomain(forName: tutorialDefaultsName)
        expect(
            ControllerProfile.cursor.bundleIdentifiers == ["com.todesktop.230313mzl4w4u92"] &&
                ControllerProfile.grokBot.bundleIdentifiers == ["com.anysphere.sand"] &&
                !ControllerProfile.xcode.bundleIdentifiers.contains("com.todesktop.230313mzl4w4u92"),
            "Cursor and Grok Bot have distinct native application profiles"
        )
        expect(
            ProfileWheelSlot.defaults.map(\.profileKind) == [.codex, .chrome, .cursor, .grokBot, .general, .finder, .terminal, .slack],
            "default wheel keeps the six retained profiles and adds Cursor and Grok Bot"
        )
        var legacyWheel = ProfileWheelSlot.defaults
        legacyWheel[2].profileKind = .claude
        legacyWheel[3].profileKind = .spotify
        expect(
            ShiftLayerStore.migrateLegacyDefaults(legacyWheel) == ProfileWheelSlot.defaults,
            "unchanged legacy assistant and music slots migrate to the new defaults"
        )
        legacyWheel[2].profileKind = .terminal
        legacyWheel[6].profileKind = .claude
        let customMigrated = ShiftLayerStore.migrateLegacyDefaults(legacyWheel)
        expect(
            customMigrated[2].profileKind == .terminal && customMigrated[6].profileKind == .claude,
            "legacy wheel migration preserves reordered custom slots"
        )
        let wheelDefaultsName = "ControlDeckTests.ProfileWheel"
        let wheelDefaults = UserDefaults(suiteName: wheelDefaultsName)!
        wheelDefaults.removePersistentDomain(forName: wheelDefaultsName)
        let wheelStore = ShiftLayerStore(defaults: wheelDefaults)
        wheelStore.setProfile(.chrome, at: 0)
        expect(
            wheelStore.slot(at: 0).profileKind == .chrome &&
                wheelStore.slot(at: 1).profileKind == .codex &&
                Set(wheelStore.profileSlots.map(\.profileKind)).count == 8,
            "assigning an existing profile swaps wheel slots without duplicates"
        )
        wheelStore.setProfile(.claude, at: 2)
        let reloadedWheel = ShiftLayerStore(defaults: wheelDefaults)
        expect(reloadedWheel.slot(at: 2).profileKind == .claude,
               "completed wheel migration does not replace later user customizations")
        wheelDefaults.removePersistentDomain(forName: wheelDefaultsName)

        var profileSelector = RadialProfileSelector()
        expect(
            profileSelector.update(x: 0, y: 0.8) == 0 &&
                profileSelector.update(x: 0.8, y: 0.8) == 1 &&
                profileSelector.update(x: 0.8, y: 0) == 2 &&
                profileSelector.update(x: 0, y: -0.8) == 4 &&
                profileSelector.update(x: -0.8, y: 0) == 6,
            "left-stick directions select the matching profile-wheel segments"
        )
        expect(
            profileSelector.update(x: 0, y: 0) == nil,
            "returning the left stick to neutral clears wheel selection"
        )

        var reasoningGate = SteppedStickGate()
        expect(
            reasoningGate.update(y: 0.7) == .smarter,
            "right-stick up selects a smarter reasoning step"
        )
        expect(
            reasoningGate.update(y: 0.9) == nil,
            "reasoning step does not repeat before returning to neutral"
        )
        expect(
            reasoningGate.update(y: 0.1) == nil &&
                reasoningGate.update(y: -0.75) == .faster,
            "neutral re-arms the faster reasoning step"
        )

        let taskSelectionFixtures = [
            RecentCodexTask(
                id: "one",
                title: "One",
                rolloutPath: "",
                updatedAt: .distantPast,
                state: .idle
            ),
            RecentCodexTask(
                id: "two",
                title: "Two",
                rolloutPath: "",
                updatedAt: .distantPast,
                state: .thinking
            )
        ]
        expect(
            TaskSelection.adjacentID(
                in: taskSelectionFixtures,
                selectedID: "one",
                offset: -1
            ) == "two",
            "selected task navigation wraps backwards"
        )
        expect(
            TaskSelection.adjacentID(
                in: taskSelectionFixtures,
                selectedID: "missing",
                offset: 1
            ) == "one",
            "missing selected task recovers to the first recent task"
        )

        let messageLog = """
        {"type":"event_msg","payload":{"type":"user_message","message":"Build the first version"}}
        {"type":"response_item","payload":{"type":"message","role":"assistant","content":[]}}
        {"type":"event_msg","payload":{"type":"user_message","message":"  Refine the recent task list\\nwith real chat text.  "}}
        {"type":"event_msg","payload":{"type":"task_started"}}
        """
        expect(
            CodexTaskMonitor.latestUserMessage(from: messageLog)
                == "Refine the recent task list with real chat text.",
            "recent task preview uses the newest real user message"
        )
        let previewTask = RecentCodexTask(
            id: "preview",
            title: "Generated chat header",
            latestMessage: "The actual latest task",
            rolloutPath: "",
            updatedAt: .distantPast,
            state: .idle
        )
        expect(
            previewTask.shortMessage == "The actual latest task" &&
                previewTask.shortTitle == "Generated chat header" &&
                previewTask.hasDistinctTitle,
            "recent task keeps the latest message primary and title secondary"
        )
        let rolloutFixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("control-deck-rollout-\(UUID().uuidString).jsonl")
        let largeToolEvent = """
        {"type":"response_item","payload":{"type":"function_call_output","output":"\(String(repeating: "x", count: 160_000))"}}
        """
        let rolloutFixture = """
        {"type":"event_msg","payload":{"type":"user_message","message":"Newest actual chat after a chunk boundary"}}
        \(largeToolEvent)
        {"type":"event_msg","payload":{"type":"task_started"}}
        """
        try! Data(rolloutFixture.utf8).write(to: rolloutFixtureURL)
        defer { try? FileManager.default.removeItem(at: rolloutFixtureURL) }
        expect(
            CodexTaskMonitor.latestUserMessage(inFileAtPath: rolloutFixtureURL.path)
                == "Newest actual chat after a chunk boundary",
            "recent task reader scans backward across large rollout chunks"
        )

        let legacyPointer = Data(
            """
            {
              "source": "left",
              "speed": 900,
              "acceleration": 1.65,
              "deadZone": 0.16
            }
            """.utf8
        )
        let migratedPointer = try! JSONDecoder().decode(
            StickPointerSettings.self,
            from: legacyPointer
        )
        expect(
            migratedPointer.scrollSource == .right &&
                migratedPointer.scrollSpeed == 1_050,
            "legacy pointer settings gain right-stick scrolling"
        )
        let legacyTouchpad = Data(
            """
            {
              "oneFingerPointer": true,
              "twoFingerScroll": true,
              "pointerSensitivity": 1,
              "scrollSensitivity": 1,
              "gestureBindings": {}
            }
            """.utf8
        )
        let migratedTouchpad = try! JSONDecoder().decode(
            TouchpadSettings.self,
            from: legacyTouchpad
        )
        expect(
            migratedTouchpad.oneFingerMode == .pointer,
            "legacy touchpad pointer setting remains compatible"
        )

        expect(migratedTouchpad.naturalScrolling, "Legacy profiles adopt natural scrolling")

        let horizontalDisplays = [
            CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
            CGRect(x: 1_920, y: 0, width: 1_280, height: 1_024)
        ]
        expect(
            DisplayGeometry.constrainedPoint(
                CGPoint(x: 2_050, y: 500),
                displays: horizontalDisplays
            ) == CGPoint(x: 2_050, y: 500),
            "pointer can enter a second display"
        )
        expect(
            DisplayGeometry.constrainedPoint(
                CGPoint(x: 3_400, y: 500),
                displays: horizontalDisplays
            ).x == 3_199,
            "pointer remains inside the outer display edge"
        )
        expect(
            DisplayGeometry.constrainedPoint(
                CGPoint(x: -80, y: 500),
                displays: [
                    CGRect(x: -1_280, y: 0, width: 1_280, height: 1_024),
                    CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
                ]
            ) == CGPoint(x: -80, y: 500),
            "pointer supports displays left of the main display"
        )

        var menuTrackingTimerFired = false
        let menuTrackingTimer = Timer(
            timeInterval: 0.005,
            repeats: false
        ) { _ in
            menuTrackingTimerFired = true
        }
        ContinuousInputRunLoop.add(menuTrackingTimer)
        _ = RunLoop.main.run(
            mode: .eventTracking,
            before: Date().addingTimeInterval(0.08)
        )
        expect(
            menuTrackingTimerFired,
            "pointer timers continue while a menu-bar menu tracks input"
        )

        expect(
            TouchGesture.swipe(fingers: 1, deltaX: -0.5, deltaY: 0.1)
                == .oneFingerSwipeLeft,
            "one-finger horizontal swipe"
        )
        expect(
            TouchGesture.swipe(fingers: 2, deltaX: 0.1, deltaY: 0.5)
                == .twoFingerSwipeUp,
            "two-finger vertical swipe"
        )
        expect(
            TouchpadSettings.trackpadDefault.action(for: .oneFingerTap)
                == .mouseLeftClick,
            "one-finger tap clicks"
        )
        expect(
            TouchpadSettings.trackpadDefault.action(for: .twoFingerTap)
                == .mouseRightClick,
            "two-finger tap right-clicks"
        )

        var gestures: [TouchGesture] = []
        var touchScrollDeltas: [CGPoint] = []
        let gestureEngine = TouchpadGestureEngine()
        gestureEngine.onGesture = { gestures.append($0) }
        gestureEngine.onScrollDelta = {
            touchScrollDeltas.append(CGPoint(x: $0, y: $1))
        }
        gestureEngine.update(
            finger: .primary,
            x: 0.1,
            y: 0.1,
            active: true
        )
        gestureEngine.update(
            finger: .primary,
            x: 0.5,
            y: 0.1,
            active: true
        )
        gestureEngine.update(
            finger: .primary,
            x: 0,
            y: 0,
            active: false
        )
        expect(
            !touchScrollDeltas.isEmpty && gestures.isEmpty,
            "one-finger movement scrolls without also firing a swipe"
        )

        gestureEngine.update(
            finger: .primary,
            x: 0.25,
            y: 0.25,
            active: true
        )
        gestureEngine.update(
            finger: .primary,
            x: 0,
            y: 0,
            active: false
        )
        expect(gestures == [.oneFingerTap], "touch engine recognizes a tap")

        gestures.removeAll()
        gestureEngine.update(
            finger: .primary,
            x: -0.3,
            y: 0.2,
            active: true
        )
        gestureEngine.update(
            finger: .secondary,
            x: 0.3,
            y: 0.2,
            active: true
        )
        gestureEngine.update(
            finger: .primary,
            x: 0,
            y: 0,
            active: false
        )
        gestureEngine.update(
            finger: .secondary,
            x: 0,
            y: 0,
            active: false
        )
        expect(gestures == [.twoFingerTap], "touch engine recognizes two fingers")

        let encoded = try! JSONEncoder().encode(ControllerProfile.spotify)
        let decoded = try! JSONDecoder().decode(
            ControllerProfile.self,
            from: encoded
        )
        expect(decoded == .spotify, "profile persistence round-trip")

        let exportDate = Date(timeIntervalSince1970: 1_700_000_000)
        let sharedData = try! ProfileTransfer.encode(
            profile: .codex,
            exportedAt: exportDate
        )
        let sharedProfile = try! ProfileTransfer.decode(sharedData)
        expect(
            sharedProfile.profile == .codex &&
                sharedProfile.format == SharedControllerProfile.formatIdentifier &&
                sharedProfile.version == SharedControllerProfile.currentVersion,
            "portable profile JSON round-trips through the versioned schema"
        )
        expect(
            ProfileTransfer.safeFilename(for: .codex) ==
                "codex.controldeck-profile",
            "portable profile export uses a predictable safe filename"
        )

        var unsafeRoot = try! JSONSerialization.jsonObject(
            with: sharedData
        ) as! [String: Any]
        unsafeRoot["script"] = "open -a Calculator"
        let unknownFieldData = try! JSONSerialization.data(withJSONObject: unsafeRoot)
        expectThrows(
            { _ = try ProfileTransfer.decode(unknownFieldData) },
            "portable profile rejects unknown executable-looking fields"
        )

        var unknownActionRoot = try! JSONSerialization.jsonObject(
            with: sharedData
        ) as! [String: Any]
        var unknownActionProfile = unknownActionRoot["profile"] as! [String: Any]
        var unknownActionBindings = unknownActionProfile["bindings"] as! [String: Any]
        unknownActionBindings[ControllerInput.cross.rawValue] = "runShellCommand"
        unknownActionProfile["bindings"] = unknownActionBindings
        unknownActionRoot["profile"] = unknownActionProfile
        let unknownActionData = try! JSONSerialization.data(
            withJSONObject: unknownActionRoot
        )
        expectThrows(
            { _ = try ProfileTransfer.decode(unknownActionData) },
            "portable profile rejects actions ControlDeck does not define"
        )

        var unsafeNumberRoot = try! JSONSerialization.jsonObject(
            with: sharedData
        ) as! [String: Any]
        var unsafeNumberProfile = unsafeNumberRoot["profile"] as! [String: Any]
        var unsafePointer = unsafeNumberProfile["pointer"] as! [String: Any]
        unsafePointer["speed"] = 1_000_000
        unsafeNumberProfile["pointer"] = unsafePointer
        unsafeNumberRoot["profile"] = unsafeNumberProfile
        let unsafeNumberData = try! JSONSerialization.data(
            withJSONObject: unsafeNumberRoot
        )
        expectThrows(
            { _ = try ProfileTransfer.decode(unsafeNumberData) },
            "portable profile rejects unsafe pointer values"
        )

        expectThrows(
            {
                _ = try ProfileTransfer.decode(
                    Data(
                        repeating: 0x20,
                        count: ProfileTransfer.maximumFileSize + 1
                    )
                )
            },
            "portable profile rejects files above the bounded read limit"
        )

        let active = """
        {"type":"event_msg","payload":{"type":"task_started"}}
        {"type":"response_item","payload":{"type":"function_call"}}
        """
        expect(
            CodexTaskMonitor.inferState(from: active) == .thinking,
            "active task state"
        )

        let complete = active + "\n" + """
        {"type":"event_msg","payload":{"type":"task_complete"}}
        """
        expect(
            CodexTaskMonitor.inferState(from: complete) == .complete,
            "completed task state"
        )

        let pendingInput = """
        {"type":"event_msg","payload":{"type":"task_started"}}
        {"type":"response_item","payload":{"name":"request_user_input"}}
        """
        expect(
            CodexTaskMonitor.inferState(from: pendingInput) == .needsInput,
            "pending input task state"
        )
        expect(
            CodexTaskState.aggregate([.idle, .thinking, .complete]) == .thinking,
            "thinking aggregation priority"
        )
        expect(
            CodexTaskState.aggregate([.thinking, .needsInput]) == .needsInput,
            "input aggregation priority"
        )
        expect(
            CodexTaskState.aggregate([.idle, .error]) == .error,
            "error aggregation priority"
        )

        let micOpen =
            DualSenseBluetoothAudioProtocol.microphoneStreamReport(
                active: true,
                sequence: 0
            )
        expect(micOpen.count == 142, "Bluetooth mic report length")
        expect(
            Array(micOpen.suffix(4)) == [0x84, 0x67, 0xe8, 0x16],
            "Bluetooth mic report Sony CRC"
        )
        let micClose =
            DualSenseBluetoothAudioProtocol.microphoneStreamReport(
                active: false,
                sequence: 0
            )
        expect(micClose[4] == 0xfe, "Bluetooth mic close command")
        expect(
            Array(micClose.suffix(4)) == [0x92, 0x90, 0xfa, 0xec],
            "Bluetooth mic close report Sony CRC"
        )

        let micState =
            DualSenseBluetoothAudioProtocol.microphoneStateReport(
                active: true,
                muted: false,
                sequence: 0
            )
        expect(micState.count == 78, "Bluetooth mic state length")
        expect(
            Array(micState.suffix(4)) == [0xb2, 0xa3, 0x47, 0x3b],
            "Bluetooth mic state Sony CRC"
        )

        let speakerOpus = [UInt8](repeating: 0x5a, count: 200)
        let speakerReport =
            DualSenseBluetoothAudioProtocol.speakerAudioReport(
                opusFrame: speakerOpus,
                reportSequence: 3,
                packetSequence: 7,
                microphoneActive: true
            )!
        expect(speakerReport.count == 398, "Bluetooth speaker report length")
        expect(speakerReport[0] == 0x36, "Bluetooth speaker report ID")
        expect(
            speakerReport[4] == 0xff,
            "Bluetooth speaker keeps an active microphone uplink"
        )
        expect(
            speakerReport[142] == 0x93 && speakerReport[143] == 200,
            "Bluetooth speaker section header"
        )
        expect(
            Array(speakerReport[144..<344]) == speakerOpus,
            "Bluetooth speaker Opus placement"
        )
        expect(
            speakerReport[13] & 0xe0 == 0xe0 &&
                speakerReport[20] == 0x39,
            "Bluetooth speaker report preserves mic and selects speaker"
        )
        let speakerChecksum = UInt32(speakerReport[394]) |
            (UInt32(speakerReport[395]) << 8) |
            (UInt32(speakerReport[396]) << 16) |
            (UInt32(speakerReport[397]) << 24)
        expect(
            speakerChecksum ==
                DualSenseBluetoothAudioProtocol.outputCRC(
                    for: Array(speakerReport[..<394])
                ),
            "Bluetooth speaker Sony CRC"
        )
        let audioInitialization =
            DualSenseBluetoothAudioProtocol.audioInitializationReport(
                microphoneActive: false,
                speakerActive: true
            )
        expect(
            audioInitialization.count == 142 &&
                audioInitialization[0] == 0x32 &&
                audioInitialization[2] == 0x90 &&
                audioInitialization[3] == 63,
            "Bluetooth audio initialization framing"
        )
        let speakerOnlyReport =
            DualSenseBluetoothAudioProtocol.speakerAudioReport(
                opusFrame: speakerOpus,
                reportSequence: 0,
                packetSequence: 0,
                microphoneActive: false
            )!
        expect(
            speakerOnlyReport[4] == 0xfe,
            "Bluetooth speaker-only packets disable the microphone uplink"
        )

        let opusFrame = [UInt8(0xd4)] +
            [UInt8](repeating: 0x55, count: 70)
        let audioReport = [UInt8(0x31), 0x02, 0x00] +
            opusFrame + [0x00, 0x00, 0x00, 0x00]
        expect(
            DualSenseBluetoothAudioProtocol.microphoneOpusPayload(
                reportID: 0x31,
                bytes: audioReport
            ) == Data(opusFrame),
            "Bluetooth audio frame extraction"
        )
        var sequencedAudioReport = audioReport
        sequencedAudioReport[1] = 0xa2
        let sequencedPacket =
            DualSenseBluetoothAudioProtocol.microphonePacket(
                reportID: 0x31,
                bytes: sequencedAudioReport,
                arrivalNanoseconds: 123_000_000
            )
        expect(
            sequencedPacket ==
                DualSenseBluetoothMicrophonePacket(
                    sequence: 0x0a,
                    opusPayload: Data(opusFrame),
                    arrivalNanoseconds: 123_000_000
                ),
            "Bluetooth audio preserves packet sequence and arrival clock"
        )
        var packetTimeline = DualSenseBluetoothPacketTimeline()
        let timelinePayload = Data(opusFrame)
        expect(
            packetTimeline.observe(
                DualSenseBluetoothMicrophonePacket(
                    sequence: 0,
                    opusPayload: timelinePayload,
                    arrivalNanoseconds: 0
                )
            ) == DualSenseBluetoothPacketTiming(
                concealCount: 0,
                timelineGaps: 0,
                isDuplicate: false
            ),
            "Bluetooth packet timeline accepts its first frame"
        )
        expect(
            packetTimeline.observe(
                DualSenseBluetoothMicrophonePacket(
                    sequence: 1,
                    opusPayload: timelinePayload,
                    arrivalNanoseconds: 10_000_000
                )
            ).concealCount == 0,
            "Bluetooth packet timeline keeps continuous audio untouched"
        )
        expect(
            packetTimeline.observe(
                DualSenseBluetoothMicrophonePacket(
                    sequence: 3,
                    opusPayload: timelinePayload,
                    arrivalNanoseconds: 30_000_000
                )
            ) == DualSenseBluetoothPacketTiming(
                concealCount: 1,
                timelineGaps: 1,
                isDuplicate: false
            ),
            "Bluetooth packet timeline identifies corroborated packet loss"
        )
        expect(
            packetTimeline.observe(
                DualSenseBluetoothMicrophonePacket(
                    sequence: 3,
                    opusPayload: timelinePayload,
                    arrivalNanoseconds: 31_000_000
                )
            ).isDuplicate,
            "Bluetooth packet timeline rejects immediate duplicates"
        )
        expect(
            DualSenseBluetoothAudioProtocol.microphoneOpusPayload(
                reportID: 0x31,
                bytes: Array(audioReport.dropFirst())
            ) == Data(opusFrame),
            "Bluetooth audio frame extraction without repeated report ID"
        )
        var strippedSequenceThree = Array(audioReport.dropFirst())
        strippedSequenceThree[0] = 0x31
        expect(
            !DualSenseBluetoothAudioProtocol.inputBufferIncludesReportID(
                reportID: 0x31,
                bytes: strippedSequenceThree
            ),
            "stripped sequence header is not mistaken for a report ID"
        )

        var controlReport = [UInt8](repeating: 0, count: 78)
        controlReport[0] = 0x31
        controlReport[1] = 0x01
        controlReport[6] = 0x80
        controlReport[9] = 0x20
        controlReport[10] = 0x04
        controlReport[11] = 0x04
        let expectedControl = DualSenseBluetoothControlFrame(
            leftTrigger: 0x80,
            buttons0: 0x20,
            buttons1: 0x04,
            buttons2: 0x04
        )
        expect(
            DualSenseBluetoothAudioProtocol.bluetoothControlFrame(
                reportID: 0x31,
                bytes: controlReport
            ) == expectedControl,
            "Bluetooth control offsets with repeated report ID"
        )
        var strippedControl = Array(controlReport.dropFirst())
        strippedControl[0] = 0x31
        expect(
            DualSenseBluetoothAudioProtocol.bluetoothControlFrame(
                reportID: 0x31,
                bytes: strippedControl
            ) == expectedControl,
            "Bluetooth control offsets with stripped sequence-three header"
        )
        expect(
            DualSenseBluetoothAudioProtocol.bluetoothControlFrame(
                reportID: 0x31,
                bytes: audioReport
            ) == nil,
            "Bluetooth Opus report cannot parse as controller state"
        )

        print("PASS: \(checks) ControlDeck logic checks")
    }
}
