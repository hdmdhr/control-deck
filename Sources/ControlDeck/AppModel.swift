import AppKit
import AudioToolbox
import Combine
import Foundation
import OSLog

@MainActor
final class AppModel: ObservableObject {
    let controller = DualSenseControllerService()
    let audio = AudioDeviceService()
    let bluetoothMicrophone = BluetoothMicrophoneService()
    let appleSpeechTranscriber = AppleSpeechTranscriptionService()
    let localSpeechTranscriber = LocalSpeechTranscriptionService()
    let automation = CodexAutomation()
    let taskMonitor = CodexTaskMonitor()
    let profiles: ProfileStore
    let shiftLayer: ShiftLayerStore
    let tutorial: QuickTutorialStore
    let screenCapturePreferences: ScreenCapturePreferences
    let screenshotEditor: ScreenshotEditorController
    let pointer = PointerService()
    let touchpad = TouchpadGestureEngine()
    let codexExtension = CodexExtensionService()
    let gyroTelemetry = GyroTelemetry()
    private var chatGPTNavigationInFlight = false
    private let sogouDictation = SogouDictationService()
    private var sogouDictationInput: ControllerInput?
    private var sogouDictationTransport: ControllerTransport?
    @Published var generalDictationBackend = ControllerPreferences.generalDictationBackend {
        didSet {
            ControllerPreferences.generalDictationBackend = generalDictationBackend
            sogouDictation.stop()
            if generalDictationBackend == .controlDeck, generalDictationEngine != .appleSpeech {
                localSpeechTranscriber.prepareModel(generalDictationEngine)
            }
        }
    }

    @Published private(set) var currentState: CodexTaskState = .disconnected
    @Published private(set) var recentTasks: [RecentCodexTask] = []
    @Published private(set) var selectedTaskID: String?
    @Published private(set) var lastAction = String(localized: "Ready", bundle: AppResources.localizationBundle)
    @Published private(set) var pushToTalkActive = false
    @Published var soundTheme = ControllerPreferences.soundTheme {
        didSet { ControllerPreferences.soundTheme = soundTheme }
    }
    @Published var statusHaptics = ControllerPreferences.statusHaptics {
        didSet { ControllerPreferences.statusHaptics = statusHaptics }
    }
    @Published var generalDictationEngine =
        ControllerPreferences.generalDictationEngine {
        didSet {
            ControllerPreferences.generalDictationEngine =
                generalDictationEngine
            if generalDictationBackend == .controlDeck, generalDictationEngine != .appleSpeech {
                localSpeechTranscriber.prepareModel(
                    generalDictationEngine
                )
            }
        }
    }
    @Published var generalDictationUsesControllerMicrophone =
        ControllerPreferences.generalDictationUsesControllerMicrophone {
        didSet {
            ControllerPreferences.generalDictationUsesControllerMicrophone =
                generalDictationUsesControllerMicrophone
        }
    }
    @Published private(set) var selfTestRunning = false
    @Published private(set) var microphoneDiagnosticRunning = false
    @Published private(set) var microphoneDiagnosticPassed = false
    @Published private(set) var microphoneDiagnosticResult =
        String(localized: "Controller microphone has not been tested yet", bundle: AppResources.localizationBundle)
    @Published private(set) var installationResult =
        String(localized: "Run from Applications for the smoothest startup experience.", bundle: AppResources.localizationBundle)
    @Published private(set) var lastGyroGesture: GyroGesture?
    @Published private(set) var gyroGameActive = false

    private let hud = HUDController()
    private let controllerOverlay = ControllerOverlayController()
    private let dictationFocusGuard = DictationFocusGuard()
    private var started = false
    private var lastStates: [String: CodexTaskState] = [:]
    private var accessibilityObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    private var caretApplicationObserver: NSObjectProtocol?
    private var caretNeutralTimer: Timer?
    private var voiceCaptureMode: VoiceCaptureMode?
    private var voiceCaptureTransport: ControllerTransport?
    private var voiceStopPending = false
    private var voiceStopGeneration = 0
    private var selfTestGeneration = 0
    private var microphoneDiagnosticGeneration = 0
    private var hybridDictationGeneration = 0
    private var hybridDictationPressed = false
    private var universalDictationActive = false
    private var universalDictationMode: VoiceCaptureMode?
    private var universalDictationGeneration = 0
    private var universalDictationPressed = false
    private var universalDictationTransport: ControllerTransport?
    private var universalDictationProvider:
        UniversalDictationProvider?
    private var universalTranscriberReady = false
    private var universalTranscriptionStopPending = false
    private var universalTranscriptionSessionGeneration = 0
    private var soundGeneration = 0
    private var heldMouseInputs: [ControllerInput: CGMouseButton] = [:]
    private var appSwitcherHold = AppSwitcherHoldGate()
    private var appSwitcherStick = AppSwitcherStickGate()
    private var appSwitcherSafetyGeneration = 0
    private var screenshotEditorCapturedInputs: Set<ControllerInput> = []
    private var tutorialCapturedInputs: Set<ControllerInput> = []
    private var optionsPressed = false
    private var optionsLayerActive = false
    private var optionsLayerUsed = false
    private var optionsGeneration = 0
    private var profileWheelSelector = RadialProfileSelector()
    private var createPressed = false
    private var createLayerUsed = false
    private var reasoningControlOpen = false
    private var reasoningControlReady = false
    private var pendingReasoningSteps: [ReasoningStep] = []
    private var reasoningGeneration = 0
    private var reasoningGate = SteppedStickGate()
    private var gyroEngine = GyroGestureEngine()
    private var telemetryRateLimiter = TelemetryRateLimiter(
        minimumInterval: 1.0 / 30.0
    )
    private var assistantDictationInput: ControllerInput?
    private var cancellables: Set<AnyCancellable> = []
    private let logger = Logger(
        subsystem: "com.ianhansel.controldeck",
        category: "app"
    )

    init() {
        let capturePreferences = ScreenCapturePreferences()
        screenCapturePreferences = capturePreferences
        screenshotEditor = ScreenshotEditorController(
            preferences: capturePreferences
        )
        tutorial = QuickTutorialStore()
        profiles = ProfileStore()
        shiftLayer = ShiftLayerStore()
        DispatchQueue.main.async { [weak self] in
            self?.start()
        }
    }

    func start() {
        guard !started else { return }
        started = true
        sogouDictation.onPressed = { [weak self] in
            guard let self else { return }
            self.lastAction = String(localized: "Right Option held · release to finish", bundle: AppResources.localizationBundle)
            self.controller.playHaptic(.selection)
        }
        sogouDictation.onReleased = { [weak self] in
            guard let self else { return }
            if let transport = self.sogouDictationTransport { self.stopVoiceCaptureResources(for: transport) }
            self.sogouDictationTransport = nil
            self.sogouDictationInput = nil
            self.lastAction = String(localized: "Right Option released", bundle: AppResources.localizationBundle)
            self.hud.dismiss()
            self.controller.playHaptic(.selection)
        }

        pointer.caretInputAllowed = { [weak self] in
            self?.caretInputAvailable == true
        }
        caretApplicationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.pointer.stopCaret()
                self?.refreshCaretNeutral()
                if (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier != SogouDictationService.bundleID {
                    self?.sogouDictation.stop()
                }
            }
        }
        let neutralTimer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshCaretNeutral() }
        }
        ContinuousInputRunLoop.add(neutralTimer)
        caretNeutralTimer = neutralTimer

        controller.onEvent = { [weak self] event in
            self?.handle(event)
        }
        controller.onBluetoothMicrophonePacket = { [weak self] packet in
            self?.bluetoothMicrophone.ingest(packet)
        }
        controller.onBluetoothMicrophoneRecoveryRequired = { [weak self] message in
            self?.feedbackFailure(message)
        }
        controller.onTransportChanged = { [weak self] transport in
            self?.controllerTransportChanged(transport)
        }
        touchpad.onPointerDelta = { [weak self] deltaX, deltaY in
            self?.pointer.moveImmediately(deltaX: deltaX, deltaY: deltaY)
        }
        touchpad.onScrollDelta = { [weak self] deltaX, deltaY in
            self?.pointer.scroll(deltaX: deltaX, deltaY: deltaY)
        }
        touchpad.onGesture = { [weak self] gesture in
            guard let self else { return }
            let action = self.profiles.activeProfile.touchpad.action(for: gesture)
            self.execute(action, source: gesture.label)
        }
        pointer.onScreenshotCaptured = { [weak self] image in
            self?.screenshotCaptured(image)
        }
        pointer.onScreenshotCaptureFailed = { [weak self] message in
            self?.feedbackFailure(message)
        }
        screenshotEditor.onDone = { [weak self] copied in
            guard let self else { return }
            self.lastAction = copied
                ? String(localized: "Edited screenshot copied to clipboard", bundle: AppResources.localizationBundle)
                : String(localized: "Screenshot editor closed", bundle: AppResources.localizationBundle)
            self.hud.show(
                copied ? String(localized: "Copied to clipboard", bundle: AppResources.localizationBundle) : String(localized: "Screenshot editor closed", bundle: AppResources.localizationBundle),
                detail: copied
                    ? String(localized: "The current image and markup are ready to paste", bundle: AppResources.localizationBundle)
                    : String(localized: "The clipboard was not changed", bundle: AppResources.localizationBundle),
                color: copied ? .systemGreen : .systemGray
            )
            self.controller.playHaptic(copied ? .success : .selection)
        }
        localSpeechTranscriber.onPartialTranscript = { [weak self] text in
            guard let self, !text.isEmpty else { return }
            self.hud.showStreaming(
                String(localized: "\(self.generalDictationEngine.label) streaming", bundle: AppResources.localizationBundle),
                detail: text,
                color: CodexTaskState.listening.color
            )
        }
        localSpeechTranscriber.onInputLevel = { [weak self] level in
            self?.hud.updateInputLevel(level)
        }
        appleSpeechTranscriber.onPartialTranscript = { [weak self] text in
            guard let self, !text.isEmpty else { return }
            self.hud.showStreaming(
                String(localized: "System dictation · live", bundle: AppResources.localizationBundle),
                detail: text,
                color: CodexTaskState.listening.color
            )
        }
        appleSpeechTranscriber.onInputLevel = { [weak self] level in
            self?.hud.updateInputLevel(level)
        }
        taskMonitor.onTasksChanged = { [weak self] tasks in
            self?.tasksChanged(tasks)
        }
        controller.$isConnected
            .removeDuplicates()
            .sink { [weak self] connected in
                if !connected {
                    self?.pointer.stop()
                    self?.endAssistantDictationHold()
                    self?.sogouDictation.stop()
                }
            }
            .store(in: &cancellables)
        profiles.$activeKind
            .combineLatest(profiles.$profiles)
            .sink { [weak self] kind, profiles in
                guard let self else { return }
                // A mapping change must also cancel pointer/scroll vectors that
                // may now belong to the caret source without a fresh report.
                self.pointer.stop()
                self.sogouDictation.stop()
                if self.assistantDictationInput != nil {
                    self.endAssistantDictationHold()
                }
                let enabled = profiles.first(where: { $0.kind == kind })?
                    .gyro.enabled ?? true
                self.controller.setMotionSensorsActive(
                    enabled || self.gyroGameActive
                )
            }
            .store(in: &cancellables)

        automation.refreshAccessibility()
        accessibilityObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.automation.refreshAccessibility()
                self?.profiles.refreshActiveProfile()
                self?.shiftLayer.reloadExternalChanges()
            }
        }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.shutdown()
            }
        }

        // Clear a process tap left behind by an unclean prior termination
        // before publishing whichever microphone matches this connection.
        bluetoothMicrophone.teardown()
        audio.refresh()
        if audio.controllerAudioAvailable {
            _ = audio.ensureCodexMicrophone()
        }
        controller.start()
        taskMonitor.start()
        if generalDictationBackend == .controlDeck, generalDictationEngine != .appleSpeech {
            localSpeechTranscriber.prepareModel(
                generalDictationEngine
            )
        }
        updateState(.idle)
        logger.notice(
            "ControlDeck started; controllerAudio=\(self.audio.controllerAudioAvailable) accessibility=\(self.automation.accessibilityTrusted)"
        )

        if CommandLine.arguments.contains("--self-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.runSelfTest()
            }
        }
        if CommandLine.arguments.contains("--wireless-mic-self-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.audio.removeCodexMicrophone()
                self?.bluetoothMicrophone.runAudioBridgeSelfTest()
            }
        }
        if CommandLine.arguments.contains("--wireless-mic-hardware-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                [weak self] in
                self?.runWirelessMicrophoneDiagnostic()
            }
        }
    }

    func requestAccessibility() {
        automation.requestAccessibility()
        if !automation.accessibilityTrusted,
           let url = URL(
               string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
           ) {
            NSWorkspace.shared.open(url)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.automation.refreshAccessibility()
        }
    }

    func openBluetoothSettings() {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.BluetoothSettings"
        ) {
            NSWorkspace.shared.open(url)
        }
    }

    func installInApplications() {
        let fileManager = FileManager.default
        let source = Bundle.main.bundleURL
        let applications = URL(
            fileURLWithPath: "/Applications",
            isDirectory: true
        )
        if source.deletingLastPathComponent() == applications {
            installationResult = String(localized: "ControlDeck is already installed.", bundle: AppResources.localizationBundle)
            return
        }
        let destination = applications.appendingPathComponent(
            source.lastPathComponent,
            isDirectory: true
        )
        guard !fileManager.fileExists(atPath: destination.path) else {
            installationResult =
                String(localized: "An existing copy is already in Applications.", bundle: AppResources.localizationBundle)
            NSWorkspace.shared.activateFileViewerSelecting([destination])
            return
        }
        do {
            try fileManager.copyItem(at: source, to: destination)
            installationResult =
                String(localized: "Installed in Applications. You can keep this window open.", bundle: AppResources.localizationBundle)
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch {
            installationResult =
                String(localized: "Drag the app into Applications: \(error.localizedDescription)", bundle: AppResources.localizationBundle)
            NSWorkspace.shared.open(applications)
        }
    }

    func openAudioCapturePrivacySettings() {
        let destinations = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ]
        if let url = destinations.compactMap(URL.init(string:)).first {
            NSWorkspace.shared.open(url)
        }
    }

    func openMicrophonePrivacySettings() {
        let destinations = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ]
        if let url = destinations.compactMap(URL.init(string:)).first {
            NSWorkspace.shared.open(url)
        }
    }

    func openSpeechRecognitionPrivacySettings() {
        let destinations = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_SpeechRecognition",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
        ]
        if let url = destinations.compactMap(URL.init(string:)).first {
            NSWorkspace.shared.open(url)
        }
    }

    func openCodexMicrophoneSettings() {
        if controller.transport == .bluetooth {
            _ = bluetoothMicrophone.prepare()
        } else if controller.transport == .usb {
            audio.refresh()
            if audio.controllerAudioAvailable {
                _ = audio.ensureCodexMicrophone()
            }
        }
        _ = automation.openSettings()
        lastAction =
            String(localized: "Choose DualSense Microphone in Codex Settings → General", bundle: AppResources.localizationBundle)
    }

    func runSelfTest() {
        guard !selfTestRunning else { return }
        guard controller.isConnected else {
            feedbackFailure(String(localized: "Connect the DualSense before running the test", bundle: AppResources.localizationBundle))
            return
        }
        guard !pushToTalkActive,
              !voiceStopPending,
              !universalDictationActive,
              !universalTranscriptionStopPending,
              !microphoneDiagnosticRunning
        else {
            feedbackFailure(
                String(localized: "Finish the microphone session before running the self-test", bundle: AppResources.localizationBundle)
            )
            return
        }
        selfTestGeneration += 1
        let generation = selfTestGeneration
        selfTestRunning = true
        pointer.stop()
        touchpad.cancel()
        lastAction = String(localized: "Testing one haptic, then one speaker tone", bundle: AppResources.localizationBundle)
        hud.show(
            String(localized: "Safe DualSense self-test", bundle: AppResources.localizationBundle),
            detail: String(localized: "One gentle haptic · one short tone", bundle: AppResources.localizationBundle),
            color: .systemCyan
        )
        controller.runSafeHapticSelfTest { [weak self] in
            guard let self,
                  self.selfTestRunning,
                  self.selfTestGeneration == generation
            else {
                return
            }
            if self.controller.transport == .bluetooth {
                self.lastAction = String(localized: "Playing one Bluetooth speaker tone", bundle: AppResources.localizationBundle)
                let started = self.controller.playBluetoothSpeakerTone(
                    frequency: 660,
                    duration: 0.10,
                    volume: 0.07
                ) { [weak self] speakerResult in
                    self?.completeSelfTest(
                        generation: generation,
                        result: speakerResult == String(localized: "Controller speaker played over Bluetooth", bundle: AppResources.localizationBundle) ? nil : speakerResult
                    )
                }
                guard started else {
                    self.completeSelfTest(
                        generation: generation,
                        result: self.controller.lastBluetoothSpeakerResult
                    )
                    return
                }
            } else if self.controller.transport == .usb,
                      self.audio.controllerAudioAvailable {
                self.lastAction = String(localized: "Playing one controller speaker tone", bundle: AppResources.localizationBundle)
                _ = self.audio.playControllerTone(
                    frequency: 660,
                    duration: 0.10,
                    volume: 0.07
                )
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                    [weak self] in
                    self?.completeSelfTest(generation: generation)
                }
            } else {
                self.completeSelfTest(generation: generation)
            }
        }
    }

    func runWirelessMicrophoneDiagnostic() {
        guard !microphoneDiagnosticRunning else { return }
        guard controller.transport == .bluetooth else {
            feedbackFailure(
                String(localized: "Connect the DualSense over Bluetooth before testing its mic", bundle: AppResources.localizationBundle)
            )
            return
        }
        guard !pushToTalkActive,
              !voiceStopPending,
              !universalDictationActive,
              !universalTranscriptionStopPending,
              !selfTestRunning
        else {
            feedbackFailure(String(localized: "Finish the current test or dictation first", bundle: AppResources.localizationBundle))
            return
        }

        microphoneDiagnosticGeneration += 1
        let generation = microphoneDiagnosticGeneration
        microphoneDiagnosticRunning = true
        microphoneDiagnosticPassed = false
        microphoneDiagnosticResult = String(localized: "Speak into the controller now…", bundle: AppResources.localizationBundle)
        pointer.stop()
        touchpad.cancel()
        audio.removeCodexMicrophone()
        guard bluetoothMicrophone.startCapture() else {
            microphoneDiagnosticRunning = false
            feedbackFailure(bluetoothMicrophone.lastResult)
            return
        }
        guard controller.setBluetoothMicrophoneCapture(true) else {
            bluetoothMicrophone.stopCapture()
            microphoneDiagnosticRunning = false
            feedbackFailure(controller.lastBluetoothMicrophoneResult)
            return
        }

        lastAction = String(localized: "Speak into the controller for three seconds", bundle: AppResources.localizationBundle)
        hud.show(
            String(localized: "Testing wireless microphone", bundle: AppResources.localizationBundle),
            detail: String(localized: "Speak now · no Codex actions will be triggered", bundle: AppResources.localizationBundle),
            color: .systemCyan
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            [weak self] in
            guard let self,
                  self.microphoneDiagnosticRunning,
                  self.microphoneDiagnosticGeneration == generation
            else {
                return
            }
            _ = self.controller.setBluetoothMicrophoneCapture(false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                [weak self] in
                self?.completeWirelessMicrophoneDiagnostic(
                    generation: generation
                )
            }
        }
    }

    func perform(_ action: ControllerAction) {
        let succeeded = automation.run(action)
        finish(action.label, succeeded: succeeded)
    }

    func perform(_ action: MappedAction) {
        execute(action, source: "ControlDeck")
    }

    func toggleVoiceCapture() {
        toggleVoiceCapture(initiator: nil)
    }

    func prepareBluetoothMicrophone() {
        audio.removeCodexMicrophone()
        if bluetoothMicrophone.prepare() {
            lastAction = String(localized: "Wireless DualSense Microphone is ready", bundle: AppResources.localizationBundle)
        } else {
            feedbackFailure(bluetoothMicrophone.lastResult)
        }
    }

    private var caretInputAvailable: Bool {
        controller.isConnected && !selfTestRunning && !microphoneDiagnosticRunning &&
        !voiceStopPending && !pushToTalkActive && !universalDictationActive && !sogouDictation.isActive &&
        !universalTranscriptionStopPending && assistantDictationInput == nil &&
        !controller.isBluetoothMicrophoneInputSuppressed && !screenshotEditor.isPresented &&
        !tutorial.isPresented && !optionsPressed && !createPressed && !appSwitcherHold.isActive
    }

    /// Only centered readings are forwarded: sampling can arm the safety gate,
    /// but a value-changed controller event must still initiate every movement.
    private func refreshCaretNeutral() {
        guard caretInputAvailable else {
            pointer.stopCaret()
            return
        }
        let settings = profiles.activeProfile.pointer
        guard let sample = controller.currentStickPosition(settings.caretSource) else { return }
        pointer.observeCaretNeutral(x: sample.x, y: sample.y, settings: settings)
    }

    private func handle(_ event: ControllerEvent) {
        if !caretInputAvailable { pointer.stopCaret() }
        // Diagnostics are output-only. Reports arriving during a hardware test
        // must never execute mouse, keyboard, Codex, browser or media actions.
        if selfTestRunning || microphoneDiagnosticRunning {
            return
        }
        if voiceStopPending {
            return
        }
        if controller.isBluetoothMicrophoneInputSuppressed,
           !isVoiceStopEvent(event) {
            // Bluetooth audio shares report 0x31 with controller state. Only
            // validated raw-HID stop controls are allowed while GameController
            // input is suppressed and the stream drains.
            return
        }

        switch event {
        case let .button(input, pressed):
            handleButton(input, pressed: pressed)
        case let .stick(stick, x, y):
            if appSwitcherHold.isActive {
                if stick == .right,
                   let direction = appSwitcherStick.update(x: x) {
                    stepAppSwitcher(direction)
                }
                return
            }
            if screenshotEditor.isPresented {
                guard stick == .left else { return }
                pointer.updateStick(
                    .left,
                    x: x,
                    y: y,
                    settings: Self.screenshotEditorPointerSettings
                )
                return
            }
            if stick == .left, optionsPressed {
                if !optionsLayerActive,
                   sqrt((x * x) + (y * y)) >= 0.28 {
                    activateOptionsLayer()
                }
                if optionsLayerActive {
                    handleProfileWheelStick(x: x, y: y)
                }
                return
            }
            if stick == .right, createPressed {
                handleReasoningStick(y: y)
                return
            }
            let pointerSettings = profiles.activeProfile.pointer
            pointer.updateCaretStick(stick, x: x, y: y, settings: pointerSettings)
            pointer.updateStick(
                stick,
                x: x,
                y: y,
                settings: pointerSettings
            )
            pointer.updateScrollStick(
                stick,
                x: x,
                y: y,
                settings: pointerSettings,
                pointerSource: pointerSettings.source
            )
        case let .touch(finger, x, y, active):
            guard !appSwitcherHold.isActive else { return }
            touchpad.settings = profiles.activeProfile.touchpad
            touchpad.update(finger: finger, x: x, y: y, active: active)
        case let .action(action):
            perform(action)
        case let .pushToTalk(active):
            setPushToTalk(
                active,
                mode: active ? .hold(.l2) : nil
            )
        case .microphoneButton:
            toggleVoiceCapture(initiator: .microphone)
        case let .motion(sample):
            handleMotion(sample)
        }
    }

    func setGyroGameActive(_ active: Bool) {
        gyroGameActive = active
        gyroEngine.reset()
        controller.setMotionSensorsActive(
            active || profiles.activeProfile.gyro.enabled
        )
        if active {
            lastAction = String(localized: "Gyro mini-game active · normal motion actions paused", bundle: AppResources.localizationBundle)
        }
    }

    func gyroGameDidReachGoal() {
        controller.playHaptic(.success)
        lastAction = String(localized: "Gyro course complete", bundle: AppResources.localizationBundle)
    }

    func gyroGameDidFall() {
        controller.playHaptic(.warning)
        lastAction = String(localized: "Gyro ball recovered · two-second penalty", bundle: AppResources.localizationBundle)
    }

    func gyroGameDidCollectToken() {
        controller.playHaptic(.selection)
        lastAction = String(localized: "Gyro time token · one second recovered", bundle: AppResources.localizationBundle)
    }

    private func handleMotion(_ sample: ControllerMotionSample) {
        if telemetryRateLimiter.shouldPublish(at: sample.timestamp) {
            gyroTelemetry.update(sample)
        }
        guard !gyroGameActive else { return }
        let settings = profiles.activeProfile.gyro
        guard let gesture = gyroEngine.update(sample, settings: settings) else {
            return
        }
        lastGyroGesture = gesture
        let action = settings.action(for: gesture)
        guard action != .none else {
            lastAction = String(localized: "\(gesture.label) detected · no action assigned", bundle: AppResources.localizationBundle)
            return
        }
        if gesture == .shake {
            controller.playHaptic(.warning)
        } else {
            controller.playHaptic(.selection)
        }
        execute(action, source: gesture.label)
    }

    private func handleButton(
        _ input: ControllerInput,
        pressed: Bool,
        allowAppSwitcherHold: Bool = true
    ) {
        // Selection release must survive overlays, layers and profile changes.
        if !pressed, sogouDictationInput == input {
            sogouDictation.stop()
            return
        }
        if sogouDictation.isActive {
            if pressed, input == .microphone || input == .circle { sogouDictation.stop() }
            return
        }
        if !pressed, pointer.isSelectionHeld(by: input) {
            pointer.setCaretSelection(input, pressed: false)
            return
        }
        // Release the initiating input before overlays, layers, and remapped profiles
        // can consume its key-up event.
        if !pressed, assistantDictationInput == input {
            endAssistantDictationHold()
            return
        }
        if pressed, input == .circle, assistantDictationInput != nil {
            endAssistantDictationHold()
            return
        }
        if !pressed, screenshotEditorCapturedInputs.remove(input) != nil {
            if input == .cross {
                pointer.setButton(.left, pressed: false)
            }
            return
        }
        if !pressed, tutorialCapturedInputs.remove(input) != nil {
            return
        }
        if screenshotEditor.isPresented {
            if pressed { screenshotEditorCapturedInputs.insert(input) }
            if input == .cross {
                pointer.setButton(.left, pressed: pressed)
                if pressed { controller.playHaptic(.selection) }
                return
            }
            guard pressed else { return }
            if let editorAction = screenshotEditor.handleControllerButton(input) {
                handleScreenshotEditorAction(editorAction)
            }
            return
        }
        if tutorial.isPresented {
            if pressed { tutorialCapturedInputs.insert(input) }
            guard pressed else { return }
            if let result = tutorial.handleControllerButton(input) {
                switch result {
                case .changedStep:
                    lastAction = String(localized: "Tutorial · \(tutorial.currentStep.title)", bundle: AppResources.localizationBundle)
                    controller.playHaptic(.selection)
                case .completed:
                    lastAction = String(localized: "Quick tutorial complete", bundle: AppResources.localizationBundle)
                    controller.playHaptic(.success)
                case .skipped:
                    lastAction = String(localized: "Tutorial skipped · replay it from Setup", bundle: AppResources.localizationBundle)
                    controller.playHaptic(.selection)
                }
            }
            return
        }
        if allowAppSwitcherHold,
           handleAppSwitcherHold(input, pressed: pressed) {
            return
        }
        if input == .options {
            handleOptionsButton(pressed: pressed)
            return
        }
        if input == .create {
            handleCreateButton(pressed: pressed)
            return
        }
        if optionsPressed {
            if pressed { optionsLayerUsed = true }
            return
        }

        if universalDictationActive,
           universalDictationMode?.initiator == input {
            handleUniversalDictation(input: input, pressed: pressed)
            return
        }
        let action = profiles.activeProfile.action(for: input)
        if !pressed, let button = heldMouseInputs.removeValue(forKey: input) {
            pointer.setButton(button, pressed: false)
            lastAction = String(localized: "\(action.label) released", bundle: AppResources.localizationBundle)
            return
        }
        if pressed, let button = mouseButton(for: action) {
            heldMouseInputs[input] = button
            pointer.setButton(button, pressed: true)
            lastAction = String(localized: "\(action.label) · hold and move to drag", bundle: AppResources.localizationBundle)
            controller.playHaptic(.selection)
            return
        }
        if action == .textSelectionHold {
            guard !pressed || caretInputAvailable else { return }
            if pressed { refreshCaretNeutral() }
            pointer.setCaretSelection(input, pressed: pressed)
            if pressed { controller.playHaptic(.selection) }
            return
        }
        if action == .cursorDictation || action == .grokDictation {
            if pressed {
                if assistantDictationInput == input { return }
                endAssistantDictationHold()
                let succeeded = automation.beginAssistantDictation(action)
                if succeeded {
                    pointer.stopCaret()
                    assistantDictationInput = input
                }
                finish(action.label, succeeded: succeeded)
            }
            return
        }
        if action == .meetingPushToTalk {
            let succeeded = automation.setMeetingPushToTalk(pressed)
            lastAction = succeeded
                ? (pressed ? String(localized: "Meeting push to talk", bundle: AppResources.localizationBundle) : String(localized: "Meeting microphone muted", bundle: AppResources.localizationBundle))
                : automation.lastResult
            if pressed && succeeded {
                controller.playHaptic(.selection)
            } else if !succeeded {
                feedbackFailure(automation.lastResult)
            }
            return
        }
        if action == .codexDictation {
            if input == .l2 {
                handleHybridDictation(input: input, pressed: pressed)
            } else if pressed {
                toggleVoiceCapture(initiator: input)
            }
            return
        }
        if action == .systemDictation {
            handleUniversalDictation(input: input, pressed: pressed)
            return
        }
        if action == .screenshotSelection {
            if pressed {
                pointer.keepScreenshotOnClipboard =
                    screenCapturePreferences.copyOriginalToClipboard ||
                    !screenCapturePreferences.openEditorAfterCapture
                if pointer.beginScreenshotSelection() {
                    lastAction =
                        String(localized: "Drag with the left stick, then release \(input.label)", bundle: AppResources.localizationBundle)
                    hud.show(
                        String(localized: "Select a screenshot area", bundle: AppResources.localizationBundle),
                        detail: String(localized: "Move with the left stick · release to capture", bundle: AppResources.localizationBundle),
                        color: .systemBlue
                    )
                    controller.playHaptic(.selection)
                } else {
                    feedbackFailure(
                        String(localized: "Accessibility is required for screenshot selection", bundle: AppResources.localizationBundle)
                    )
                }
            } else if pointer.isSelectingScreenshot {
                pointer.endScreenshotSelection()
                lastAction = String(localized: "Finishing screen capture", bundle: AppResources.localizationBundle)
                controller.playHaptic(.success)
            }
            return
        }
        guard pressed else { return }
        execute(action, source: input.label)
    }

    private func endAssistantDictationHold() {
        automation.endAssistantDictation()
        assistantDictationInput = nil
    }

    private func handleAppSwitcherHold(
        _ input: ControllerInput,
        pressed: Bool
    ) -> Bool {
        switch appSwitcherHold.handle(input, pressed: pressed) {
        case .passThrough:
            return false
        case let .deferTouchpadTap(generation):
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                [weak self] in
                guard let self,
                      self.appSwitcherHold.activate(generation: generation)
                else {
                    return
                }
                self.beginAppSwitcherHold()
            }
        case .performTouchpadTap:
            handleButton(
                .touchpadClick,
                pressed: true,
                allowAppSwitcherHold: false
            )
            handleButton(
                .touchpadClick,
                pressed: false,
                allowAppSwitcherHold: false
            )
        case .forward:
            stepAppSwitcher(.forward)
        case .backward:
            stepAppSwitcher(.backward)
        case .select:
            appSwitcherSafetyGeneration += 1
            appSwitcherStick.reset()
            let succeeded = automation.endAppSwitcher()
            lastAction = succeeded
                ? String(localized: "Application selected", bundle: AppResources.localizationBundle)
                : automation.lastResult
            if succeeded {
                controller.playHaptic(.selection)
            } else {
                feedbackFailure(automation.lastResult)
            }
        case .cancel:
            appSwitcherSafetyGeneration += 1
            appSwitcherStick.reset()
            let succeeded = automation.cancelAppSwitcher()
            lastAction = succeeded
                ? String(localized: "App switcher cancelled", bundle: AppResources.localizationBundle)
                : automation.lastResult
            if succeeded {
                hud.show(String(localized: "App switcher cancelled", bundle: AppResources.localizationBundle), color: .systemGray)
                controller.playHaptic(.selection)
            } else {
                feedbackFailure(automation.lastResult)
            }
        case .consume:
            break
        }
        return true
    }

    private func beginAppSwitcherHold() {
        pointer.stopCaret()
        guard automation.beginAppSwitcher() else {
            failAppSwitcherHold(automation.lastResult)
            return
        }
        appSwitcherSafetyGeneration += 1
        appSwitcherStick.reset()
        let safetyGeneration = appSwitcherSafetyGeneration
        lastAction = String(localized: "App switcher · release touchpad to select", bundle: AppResources.localizationBundle)
        hud.show(
            String(localized: "App switcher", bundle: AppResources.localizationBundle),
            detail: String(localized: "Right stick or D-pad to move · Circle cancels", bundle: AppResources.localizationBundle),
            color: .systemBlue
        )
        controller.playHaptic(.selection)

        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            [weak self] in
            guard let self,
                  self.appSwitcherSafetyGeneration == safetyGeneration,
                  self.appSwitcherHold.isActive
            else {
                return
            }
            _ = self.appSwitcherHold.cancel()
            _ = self.automation.cancelAppSwitcher()
            self.appSwitcherSafetyGeneration += 1
            self.lastAction = String(localized: "App switcher timed out safely", bundle: AppResources.localizationBundle)
            self.hud.show(
                String(localized: "App switcher closed", bundle: AppResources.localizationBundle),
                detail: String(localized: "Hold the touchpad click again to reopen it", bundle: AppResources.localizationBundle),
                color: .systemGray
            )
            self.controller.playHaptic(.warning)
        }
    }

    private func failAppSwitcherHold(_ message: String) {
        appSwitcherSafetyGeneration += 1
        appSwitcherStick.reset()
        if appSwitcherHold.cancel() {
            _ = automation.cancelAppSwitcher()
        }
        feedbackFailure(message)
    }

    private func stepAppSwitcher(_ direction: AppSwitcherStickDirection) {
        let succeeded: Bool
        switch direction {
        case .forward:
            succeeded = automation.advanceAppSwitcher()
        case .backward:
            succeeded = automation.reverseAppSwitcher()
        }
        guard succeeded else {
            failAppSwitcherHold(automation.lastResult)
            return
        }
        lastAction = direction == .forward
            ? String(localized: "App switcher · next application", bundle: AppResources.localizationBundle)
            : String(localized: "App switcher · previous application", bundle: AppResources.localizationBundle)
        controller.playHaptic(.selection)
    }

    private func mouseButton(for action: MappedAction) -> CGMouseButton? {
        switch action {
        case .mouseLeftClick: .left
        case .mouseRightClick: .right
        case .mouseMiddleClick: .center
        default: nil
        }
    }

    private func screenshotCaptured(_ image: NSImage) {
        pointer.stop()
        if screenCapturePreferences.openEditorAfterCapture {
            screenshotEditor.present(image: image)
            lastAction = screenCapturePreferences.copyOriginalToClipboard
                ? String(localized: "Screenshot copied · editor open", bundle: AppResources.localizationBundle)
                : String(localized: "Screenshot editor open", bundle: AppResources.localizationBundle)
            hud.show(
                String(localized: "Screen capture ready", bundle: AppResources.localizationBundle),
                detail: String(localized: "Edit with the controller or dismiss with Circle", bundle: AppResources.localizationBundle),
                color: .systemCyan
            )
        } else {
            lastAction = String(localized: "Screenshot copied to clipboard", bundle: AppResources.localizationBundle)
            hud.show(
                String(localized: "Screenshot copied", bundle: AppResources.localizationBundle),
                detail: String(localized: "Ready to paste", bundle: AppResources.localizationBundle),
                color: .systemGreen
            )
        }
        controller.playHaptic(.success)
    }

    private func handleScreenshotEditorAction(
        _ action: ScreenshotEditorControllerAction
    ) {
        switch action {
        case let .tool(tool):
            lastAction = String(localized: "Screenshot tool · \(tool)", bundle: AppResources.localizationBundle)
            controller.playHaptic(.selection)
        case .undo:
            lastAction = String(localized: "Screenshot edit undone", bundle: AppResources.localizationBundle)
            controller.playHaptic(.selection)
        case .redo:
            lastAction = String(localized: "Screenshot edit redone", bundle: AppResources.localizationBundle)
            controller.playHaptic(.selection)
        case .copied:
            lastAction = String(localized: "Edited screenshot copied", bundle: AppResources.localizationBundle)
            controller.playHaptic(.success)
        case .saved:
            lastAction = String(localized: "Edited screenshot saved", bundle: AppResources.localizationBundle)
            controller.playHaptic(.success)
        case .dismissed:
            lastAction = String(localized: "Screenshot editor dismissed · original kept", bundle: AppResources.localizationBundle)
            controller.playHaptic(.selection)
        case .done:
            break
        }
    }

    private static var screenshotEditorPointerSettings: StickPointerSettings {
        StickPointerSettings(
            source: .left,
            speed: 1_050,
            acceleration: 1.65,
            deadZone: 0.12,
            scrollSource: .off,
            caretSource: .off,
            scrollSpeed: 0,
            scrollAcceleration: 1,
            scrollDeadZone: 0.2
        )
    }

    private func handleOptionsButton(pressed: Bool) {
        if pressed {
            guard !optionsPressed else { return }
            pointer.stopCaret()
            optionsPressed = true
            optionsLayerActive = false
            optionsLayerUsed = false
            profileWheelSelector.reset()
            optionsGeneration += 1
            let generation = optionsGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                [weak self] in
                guard let self,
                      self.optionsPressed,
                      self.optionsGeneration == generation,
                      !self.optionsLayerActive
                else {
                    return
                }
                self.activateOptionsLayer()
            }
            return
        }

        guard optionsPressed else { return }
        optionsPressed = false
        refreshCaretNeutral()
        optionsGeneration += 1
        let selectedIndex = profileWheelSelector.selectedIndex
        let shouldRunTapAction = !optionsLayerActive && !optionsLayerUsed
        optionsLayerActive = false
        profileWheelSelector.reset()
        controllerOverlay.hide()
        if let selectedIndex {
            let slot = shiftLayer.slot(at: selectedIndex)
            let profile = profiles.profile(for: slot.profileKind)
            let activationToken = profiles.setActiveProfileFromWheel(slot.profileKind)
            Task { @MainActor [weak self] in
                let outcome = await ProfileApplicationActivator.activate(profile)
                let targetBundleIdentifier: String?
                if case let .activationRequested(identifier) = outcome {
                    targetBundleIdentifier = identifier
                } else {
                    targetBundleIdentifier = nil
                }
                guard let self, self.profiles.finishWheelActivation(
                    activationToken, targetBundleIdentifier: targetBundleIdentifier
                ) else { return }
                let detail: String
                let success: Bool
                switch outcome {
                case .profileOnly:
                    detail = String(localized: "Controller profile selected", bundle: AppResources.localizationBundle)
                    success = true
                case .activationRequested:
                    detail = String(localized: "App activation requested", bundle: AppResources.localizationBundle)
                    success = true
                case .unavailable:
                    detail = String(localized: "Profile selected · assigned app not found", bundle: AppResources.localizationBundle)
                    success = false
                case .failed:
                    detail = String(localized: "Profile selected · could not activate app", bundle: AppResources.localizationBundle)
                    success = false
                }
                self.lastAction = "\(profile.displayName) · \(detail)"
                self.hud.show(profile.displayName, detail: detail, color: success ? .systemCyan : .systemOrange)
                if success { self.controller.playHaptic(.success) }
            }
            return
        }
        if shouldRunTapAction {
            execute(
                profiles.activeProfile.action(for: .options),
                source: ControllerInput.options.label
            )
        }
    }

    private func activateOptionsLayer() {
        optionsLayerActive = true
        controllerOverlay.showProfileWheel(
            profiles: profiles.profiles,
            slots: shiftLayer.profileSlots,
            activeKind: profiles.activeKind,
            selectedIndex: profileWheelSelector.selectedIndex
        )
        lastAction = String(localized: "Profile wheel · choose with the left stick", bundle: AppResources.localizationBundle)
        controller.playHaptic(.selection)
    }

    private func handleProfileWheelStick(x: Float, y: Float) {
        let previous = profileWheelSelector.selectedIndex
        let selected = profileWheelSelector.update(x: x, y: y)
        guard selected != previous else { return }
        controllerOverlay.showProfileWheel(
            profiles: profiles.profiles,
            slots: shiftLayer.profileSlots,
            activeKind: profiles.activeKind,
            selectedIndex: selected
        )
        if let selected {
            let profile = profiles.profile(
                for: shiftLayer.slot(at: selected).profileKind
            )
            lastAction = String(localized: "Profile wheel · \(profile.displayName)", bundle: AppResources.localizationBundle)
            controller.playHaptic(.selection)
        }
    }

    private func handleCreateButton(pressed: Bool) {
        if pressed {
            guard !createPressed else { return }
            pointer.stopCaret()
            createPressed = true
            createLayerUsed = false
            reasoningControlOpen = false
            reasoningControlReady = false
            pendingReasoningSteps.removeAll()
            reasoningGate.reset()
            reasoningGeneration += 1
            return
        }

        guard createPressed else { return }
        createPressed = false
        refreshCaretNeutral()
        reasoningGate.reset()
        controllerOverlay.hide()
        if createLayerUsed {
            if reasoningControlOpen, reasoningControlReady {
                automation.finishReasoningAdjustment()
                reasoningControlOpen = false
                reasoningControlReady = false
            }
        } else {
            execute(
                profiles.activeProfile.action(for: .create),
                source: ControllerInput.create.label
            )
        }
    }

    private func handleReasoningStick(y: Float) {
        guard let step = reasoningGate.update(y: y) else { return }
        createLayerUsed = true
        controllerOverlay.showReasoning(
            profile: profiles.activeProfile,
            task: overlayTask,
            step: step
        )
        lastAction = String(localized: "Reasoning · \(step.title)", bundle: AppResources.localizationBundle)
        controller.playHaptic(.selection)

        if reasoningControlOpen {
            if reasoningControlReady {
                _ = automation.adjustReasoning(step)
            } else {
                pendingReasoningSteps.append(step)
            }
            return
        }

        reasoningControlOpen = true
        reasoningControlReady = false
        pendingReasoningSteps = [step]
        reasoningGeneration += 1
        let generation = reasoningGeneration
        let started = automation.beginReasoningAdjustment {
            [weak self] in
            guard let self, self.reasoningGeneration == generation else {
                return
            }
            if self.createPressed {
                self.reasoningControlReady = true
                for pendingStep in self.pendingReasoningSteps {
                    _ = self.automation.adjustReasoning(pendingStep)
                }
                self.pendingReasoningSteps.removeAll()
            } else {
                self.automation.finishReasoningAdjustment()
                self.reasoningControlOpen = false
                self.reasoningControlReady = false
                self.pendingReasoningSteps.removeAll()
            }
        }
        if !started {
            reasoningControlOpen = false
            reasoningControlReady = false
            pendingReasoningSteps.removeAll()
            feedbackFailure(automation.lastResult)
        }
    }

    private func handleHybridDictation(
        input: ControllerInput,
        pressed: Bool
    ) {
        if pressed {
            hybridDictationPressed = true
            hybridDictationGeneration += 1
            let generation = hybridDictationGeneration

            if pushToTalkActive,
               voiceCaptureMode == .toggle(input) {
                setPushToTalk(false, handsFree: true)
                return
            }
            guard !pushToTalkActive else { return }
            setPushToTalk(
                true,
                mode: .pendingTapOrHold(input)
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) {
                [weak self] in
                guard let self,
                      self.hybridDictationPressed,
                      self.hybridDictationGeneration == generation,
                      self.voiceCaptureMode == .pendingTapOrHold(input)
                else {
                    return
                }
                self.voiceCaptureMode = .hold(input)
                self.lastAction = String(localized: "Release \(input.label) to stop dictation", bundle: AppResources.localizationBundle)
            }
            return
        }

        hybridDictationPressed = false
        hybridDictationGeneration += 1
        switch voiceCaptureMode {
        case .pendingTapOrHold(input):
            voiceCaptureMode = .toggle(input)
            lastAction = String(localized: "Hands-free dictation · tap \(input.label) to stop", bundle: AppResources.localizationBundle)
            hud.show(
                String(localized: "Hands-free Codex dictation", bundle: AppResources.localizationBundle),
                detail: String(localized: "Tap \(input.label) again to stop and insert", bundle: AppResources.localizationBundle),
                color: CodexTaskState.listening.color
            )
            controller.playHaptic(.selection)
        case .hold(input):
            setPushToTalk(false)
        default:
            break
        }
    }

    private func handleUniversalDictation(
        input: ControllerInput,
        pressed: Bool
    ) {
        if generalDictationBackend == .sogouAssistant, profiles.activeKind != .claude {
            handleSogouDictation(input: input, pressed: pressed)
            return
        }
        if pressed {
            universalDictationPressed = true
            universalDictationGeneration += 1
            let generation = universalDictationGeneration

            if universalDictationActive,
               universalDictationMode == .toggle(input) {
                stopUniversalDictation(handsFree: true)
                return
            }
            guard !universalDictationActive else { return }
            guard !universalTranscriptionStopPending else {
                feedbackFailure(
                    String(localized: "Transcription is finishing the previous message", bundle: AppResources.localizationBundle)
                )
                return
            }

            pointer.stop()
            touchpad.cancel()
            if profiles.activeKind == .claude,
               automation.startClaudeDictation() {
                universalTranscriptionSessionGeneration += 1
                universalDictationProvider = .claudeNative
                universalDictationTransport = nil
                universalDictationActive = true
                universalDictationMode = .pendingTapOrHold(input)
                universalTranscriberReady = true
                lastAction = String(localized: "Claude dictation is listening", bundle: AppResources.localizationBundle)
                hud.show(
                    String(localized: "Claude dictation", bundle: AppResources.localizationBundle),
                    detail: String(localized: "Using Claude's native transcription", bundle: AppResources.localizationBundle),
                    color: CodexTaskState.listening.color
                )
                controller.playHaptic(.selection)
                scheduleUniversalHoldDetection(
                    input: input,
                    generation: generation
                )
                return
            }

            if generalDictationBackend == .sogouAssistant {
                handleSogouDictation(input: input, pressed: true)
                return
            }
            guard let insertionTarget =
                SpeechTextInsertionTarget.capture()
            else {
                feedbackFailure(
                    String(localized: "Focus the app where dictated text should be inserted", bundle: AppResources.localizationBundle)
                )
                return
            }
            dictationFocusGuard.begin(
                targetApplication: insertionTarget.targetApplication
            )
            let requestedTransport = controller.transport
            let requestedEngine = generalDictationEngine
            let usesControllerMicrophone =
                generalDictationUsesControllerMicrophone &&
                    requestedTransport != .unknown
            var usesExternalPCM = false
            var inputDeviceID: AudioObjectID?
            if requestedTransport == .usb, usesControllerMicrophone {
                audio.refresh()
                inputDeviceID = audio.speechInputDeviceID()
                lastAction = inputDeviceID == nil
                    ? String(localized: "Preparing the Mac microphone for \(requestedEngine.label)", bundle: AppResources.localizationBundle)
                    : String(localized: "Preparing the DualSense microphone for \(requestedEngine.label)", bundle: AppResources.localizationBundle)
            } else if requestedTransport == .bluetooth,
                      usesControllerMicrophone {
                usesExternalPCM = true
                lastAction =
                    String(localized: "Preparing the wireless microphone for \(requestedEngine.label)", bundle: AppResources.localizationBundle)
                audio.removeCodexMicrophone()
                guard bluetoothMicrophone.startCapture() else {
                    dictationFocusGuard.end()
                    feedbackFailure(bluetoothMicrophone.lastResult)
                    return
                }
                controller.reinforceSystemGestureSuppression()
                guard controller.setBluetoothMicrophoneCapture(true) else {
                    bluetoothMicrophone.stopCapture()
                    dictationFocusGuard.end()
                    feedbackFailure(controller.lastBluetoothMicrophoneResult)
                    return
                }
                // Apple transcription consumes decoded controller PCM directly.
                // The separately published Core Audio device remains available
                // to apps that need a conventional microphone endpoint.
            } else {
                lastAction =
                    String(localized: "Preparing the Mac microphone for \(requestedEngine.label)", bundle: AppResources.localizationBundle)
            }

            universalTranscriptionSessionGeneration += 1
            let speechSession = universalTranscriptionSessionGeneration
            universalDictationProvider = requestedEngine == .appleSpeech
                ? .appleSpeech
                : .localSpeech
            universalDictationTransport = requestedTransport
            universalTranscriberReady = false
            universalDictationActive = true
            universalDictationMode = .pendingTapOrHold(input)

            let started: Bool
            if requestedEngine != .appleSpeech {
                started = localSpeechTranscriber.begin(
                    engine: requestedEngine,
                    inputDeviceID: inputDeviceID,
                    usesExternalPCM: usesExternalPCM,
                    target: insertionTarget,
                    contextualStrings: speechContextualStrings()
                ) { [weak self] result in
                    guard let self,
                          self.universalTranscriptionSessionGeneration ==
                            speechSession
                    else { return }
                    switch result {
                    case .success:
                        self.universalTranscriberReady = true
                        self.lastAction =
                            String(localized: "\(requestedEngine.label) is listening", bundle: AppResources.localizationBundle)
                    case let .failure(error):
                        self.failUniversalTranscriptionStart(
                            error.localizedDescription
                        )
                        if case .microphonePermissionDenied = error {
                            self.openMicrophonePrivacySettings()
                        }
                    }
                }
            } else {
                started = appleSpeechTranscriber.begin(
                    inputDeviceID: inputDeviceID,
                    externalPCMSampleRate: usesExternalPCM
                        ? Double(
                            DualSenseBluetoothAudioProtocol
                                .microphoneSampleRate
                        )
                        : nil,
                    target: insertionTarget,
                    contextualStrings: speechContextualStrings()
                ) { [weak self] result in
                    guard let self,
                          self.universalTranscriptionSessionGeneration ==
                            speechSession
                    else { return }
                    switch result {
                    case .success:
                        self.universalTranscriberReady = true
                        self.lastAction =
                            String(localized: "Apple SpeechTranscriber is listening", bundle: AppResources.localizationBundle)
                    case let .failure(error):
                        self.failUniversalTranscriptionStart(
                            error.localizedDescription
                        )
                        switch error {
                        case .microphonePermissionDenied:
                            self.openMicrophonePrivacySettings()
                        case .speechPermissionDenied:
                            self.openSpeechRecognitionPrivacySettings()
                        default:
                            break
                        }
                    }
                }
            }
            guard started else {
                return
            }
            if usesExternalPCM {
                bluetoothMicrophone.setDecodedPCMHandler(
                    requestedEngine != .appleSpeech
                        ? localSpeechTranscriber.externalPCMHandler
                        : appleSpeechTranscriber.externalPCMHandler
                )
            }
            if requestedTransport == .usb, usesControllerMicrophone {
                controller.setMicrophoneLED(.off)
            }
            lastAction = String(localized: "Preparing \(requestedEngine.label)", bundle: AppResources.localizationBundle)
            hud.show(
                requestedEngine != .appleSpeech
                    ? String(localized: "\(requestedEngine.label) dictation", bundle: AppResources.localizationBundle)
                    : String(localized: "Apple dictation", bundle: AppResources.localizationBundle),
                detail: !usesControllerMicrophone
                    ? String(localized: "Using the Mac’s selected input · the text field stays focused", bundle: AppResources.localizationBundle)
                    : requestedEngine == .parakeetEOU120M
                    ? String(localized: "Low-latency local streaming · live text appears here", bundle: AppResources.localizationBundle)
                    : requestedEngine == .whisperKitBaseEnglish
                    ? String(localized: "Local Whisper transcription · finalized when you stop", bundle: AppResources.localizationBundle)
                    : String(localized: "On-device transcription · the text field stays focused", bundle: AppResources.localizationBundle),
                color: CodexTaskState.listening.color
            )
            controller.playHaptic(.selection)

            scheduleUniversalHoldDetection(
                input: input,
                generation: generation
            )
            return
        }

        universalDictationPressed = false
        universalDictationGeneration += 1
        switch universalDictationMode {
        case .pendingTapOrHold(input):
            universalDictationMode = .toggle(input)
            lastAction = String(localized: "Hands-free dictation · tap \(input.label) to stop", bundle: AppResources.localizationBundle)
            hud.show(
                String(localized: "Hands-free dictation", bundle: AppResources.localizationBundle),
                detail: String(localized: "Tap \(input.label) again to stop", bundle: AppResources.localizationBundle),
                color: CodexTaskState.listening.color
            )
            controller.playHaptic(.selection)
        case .hold:
            stopUniversalDictation(handsFree: false)
        default:
            break
        }
    }

    private func speechContextualStrings() -> [String] {
        var terms = [
            "ControlDeck",
            "DualSense",
            "Codex",
            "OpenAI",
            "Claude",
            "Anthropic",
            "WhisperKit",
            "Parakeet",
            profiles.activeProfile.displayName,
            profiles.activeProfile.kind.label
        ]
        if let appName =
            NSWorkspace.shared.frontmostApplication?.localizedName {
            terms.append(appName)
        }
        switch profiles.activeProfile.kind {
        case .codex, .xcode, .terminal:
            terms += [
                "Swift",
                "SwiftUI",
                "AppKit",
                "GitHub",
                "pull request",
                "repository",
                "terminal"
            ]
        case .spotify, .logic:
            terms += ["playlist", "track", "album", "Spotify", "Logic Pro"]
        case .chrome:
            terms += ["Google Chrome", "website", "browser", "new tab"]
        default:
            break
        }
        var seen = Set<String>()
        return terms.filter {
            !$0.isEmpty && seen.insert($0.lowercased()).inserted
        }
    }

    private func handleSogouDictation(input: ControllerInput, pressed: Bool) {
        guard pressed else { sogouDictation.stop(); return }
        guard !pushToTalkActive, !universalDictationActive, !universalTranscriptionStopPending else { return }
        pointer.stop(); touchpad.cancel()
        if generalDictationUsesControllerMicrophone {
            let transport = controller.transport
            if transport == .bluetooth {
                guard bluetoothMicrophone.prepare(), bluetoothMicrophone.startCapture(),
                      controller.setBluetoothMicrophoneCapture(true) else {
                    stopVoiceCaptureResources(for: transport)
                    feedbackFailure(bluetoothMicrophone.lastResult)
                    return
                }
                sogouDictationTransport = transport
            } else if transport == .usb {
                audio.refresh()
                guard audio.ensureCodexMicrophone() else {
                    feedbackFailure(audio.lastAudioResult)
                    return
                }
                sogouDictationTransport = transport
            } else {
                feedbackFailure(String(localized: "Controller microphone unavailable", bundle: AppResources.localizationBundle))
                return
            }
        }
        guard sogouDictation.begin() else {
            if let transport = sogouDictationTransport { stopVoiceCaptureResources(for: transport) }
            sogouDictationTransport = nil
            feedbackFailure(String(localized: "Unable to press right Option. Check Accessibility access and release other modifier keys.", bundle: AppResources.localizationBundle))
            return
        }
        sogouDictationInput = input
    }

    private func stopUniversalDictation(handsFree: Bool) {
        universalDictationActive = false
        universalDictationMode = nil
        universalDictationPressed = false
        universalDictationGeneration += 1
        universalTranscriptionStopPending = true
        let speechSession = universalTranscriptionSessionGeneration
        let transport = universalDictationTransport ?? controller.transport
        let provider = universalDictationProvider

        if universalDictationProvider == .claudeNative {
            universalTranscriptionStopPending = false
            universalTranscriberReady = false
            universalDictationProvider = nil
            let stopped = automation.stopClaudeDictation()
            if stopped {
                lastAction = String(localized: "Claude dictation complete", bundle: AppResources.localizationBundle)
                hud.show(
                    String(localized: "Claude dictation complete", bundle: AppResources.localizationBundle),
                    detail: String(localized: "Claude's native transcript is ready", bundle: AppResources.localizationBundle),
                    color: .systemGreen
                )
                controller.playHaptic(.success)
            } else {
                feedbackFailure(automation.lastResult)
            }
            updateAggregateState()
            return
        }

        let stopTranscription = { [weak self] in
            guard let self,
                  self.universalTranscriptionSessionGeneration ==
                    speechSession
            else { return }
            if provider == .localSpeech {
                let engine = self.generalDictationEngine
                let stopped = self.localSpeechTranscriber.finish(
                    recordingStopped: { [weak self] in
                        guard let self,
                              self.universalTranscriptionSessionGeneration ==
                                speechSession
                        else { return }
                        self.stopVoiceCaptureResources(for: transport)
                        self.universalDictationTransport = nil
                        self.universalTranscriberReady = false
                    }
                ) { [weak self] result in
                    guard let self,
                          self.universalTranscriptionSessionGeneration ==
                            speechSession
                    else { return }
                    self.universalTranscriptionStopPending = false
                    self.universalTranscriberReady = false
                    self.universalDictationProvider = nil
                    self.universalDictationTransport = nil
                    switch result {
                    case let .success(transcription):
                        self.dictationFocusGuard.end()
                        let fallbackDetail = transcription.usedFallback
                            ? "Live transcription recovered with \(transcription.engineUsed.engineName)"
                            : transcription.insertionMethod == .accessibility
                                ? "Transcript inserted directly"
                                : "Transcript inserted using a protected paste"
                        self.lastAction =
                            String(localized: "\(transcription.engineUsed.engineName) transcript inserted into the focused text field", bundle: AppResources.localizationBundle)
                        self.hud.show(
                            handsFree
                                ? String(localized: "\(transcription.engineUsed.label) dictation complete", bundle: AppResources.localizationBundle)
                                : String(localized: "Dictation complete", bundle: AppResources.localizationBundle),
                            detail: fallbackDetail,
                            color: .systemGreen
                        )
                        self.controller.playHaptic(.success)
                    case let .failure(error):
                        self.dictationFocusGuard.end()
                        self.feedbackFailure(error.localizedDescription)
                    }
                    self.updateAggregateState()
                }
                if stopped {
                    self.universalDictationProvider = nil
                    self.lastAction = String(localized: "\(engine.label) is finalizing", bundle: AppResources.localizationBundle)
                    self.hud.show(
                        String(localized: "Finalizing \(engine.label)", bundle: AppResources.localizationBundle),
                        detail:
                            String(localized: "The result will appear in the focused text field", bundle: AppResources.localizationBundle),
                        color: .white
                    )
                } else {
                    self.universalTranscriptionStopPending = false
                    self.universalTranscriberReady = false
                    self.stopVoiceCaptureResources(for: transport)
                    self.universalDictationTransport = nil
                    self.dictationFocusGuard.end()
                    self.feedbackFailure(
                        String(localized: "\(engine.label) could not stop cleanly", bundle: AppResources.localizationBundle)
                    )
                }
                return
            }

            let stopped = self.appleSpeechTranscriber.finish(
                recordingStopped: { [weak self] in
                    guard let self,
                          self.universalTranscriptionSessionGeneration ==
                            speechSession
                    else { return }
                    self.stopVoiceCaptureResources(for: transport)
                    self.universalDictationTransport = nil
                    self.universalTranscriberReady = false
                }
            ) { [weak self] result in
                guard let self,
                      self.universalTranscriptionSessionGeneration ==
                        speechSession
                else { return }
                self.universalTranscriptionStopPending = false
                self.universalTranscriberReady = false
                self.universalDictationProvider = nil
                self.universalDictationTransport = nil
                switch result {
                case let .success(transcription):
                    self.dictationFocusGuard.end()
                    self.lastAction =
                        String(localized: "Apple transcript inserted into the focused text field", bundle: AppResources.localizationBundle)
                    self.hud.show(
                        handsFree
                            ? String(localized: "Apple dictation complete", bundle: AppResources.localizationBundle)
                            : String(localized: "Dictation complete", bundle: AppResources.localizationBundle),
                        detail: transcription.insertionMethod ==
                            .accessibility
                            ? String(localized: "Text inserted directly into the focused field", bundle: AppResources.localizationBundle)
                            : String(localized: "Text inserted using a protected paste", bundle: AppResources.localizationBundle),
                        color: .systemGreen
                    )
                    self.controller.playHaptic(.success)
                case let .failure(error):
                    self.dictationFocusGuard.end()
                    self.feedbackFailure(error.localizedDescription)
                }
                self.updateAggregateState()
            }
            if stopped {
                self.universalDictationProvider = nil
                self.lastAction = String(localized: "Apple SpeechTranscriber is finishing", bundle: AppResources.localizationBundle)
                self.hud.show(
                    String(localized: "Transcribing on this Mac", bundle: AppResources.localizationBundle),
                    detail: String(localized: "The result will appear in the focused text field", bundle: AppResources.localizationBundle),
                    color: .white
                )
            } else {
                self.universalTranscriptionStopPending = false
                self.universalTranscriberReady = false
                self.stopVoiceCaptureResources(for: transport)
                self.universalDictationTransport = nil
                self.feedbackFailure(
                    String(localized: "Apple SpeechTranscriber could not stop cleanly", bundle: AppResources.localizationBundle)
                )
                self.dictationFocusGuard.end()
            }
        }

        if transport == .bluetooth, universalTranscriberReady {
            _ = controller.setBluetoothMicrophoneCapture(false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                stopTranscription()
            }
        } else {
            stopTranscription()
        }
    }

    private func failUniversalTranscriptionStart(_ message: String) {
        universalDictationActive = false
        universalDictationMode = nil
        universalDictationPressed = false
        universalTranscriberReady = false
        universalTranscriptionStopPending = false
        universalDictationProvider = nil
        dictationFocusGuard.end()
        if let transport = universalDictationTransport {
            stopVoiceCaptureResources(for: transport)
        }
        universalDictationTransport = nil
        hud.dismiss()
        feedbackFailure(message)
    }

    private func scheduleUniversalHoldDetection(
        input: ControllerInput,
        generation: Int
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) {
            [weak self] in
            guard let self,
                  self.universalDictationPressed,
                  self.universalDictationGeneration == generation,
                  self.universalDictationMode == .pendingTapOrHold(input)
            else {
                return
            }
            self.universalDictationMode = .hold(input)
            self.lastAction =
                String(localized: "Release \(input.label) to stop universal dictation", bundle: AppResources.localizationBundle)
        }
    }

    private func execute(_ action: MappedAction, source: String) {
        guard action != .none else {
            lastAction = String(localized: "\(source) has no assigned action", bundle: AppResources.localizationBundle)
            return
        }

        switch action {
        case .mouseLeftClick:
            pointer.click(.left)
            finish(action.label, succeeded: true)
        case .mouseRightClick:
            pointer.click(.right)
            finish(action.label, succeeded: true)
        case .mouseMiddleClick:
            pointer.click(.center)
            finish(action.label, succeeded: true)
        case .codexDictation:
            toggleVoiceCapture()
        case .systemDictation:
            toggleUniversalDictation()
        case .codexPreviousTask:
            selectAdjacentTask(offset: -1)
        case .codexNextTask:
            selectAdjacentTask(offset: 1)
        case .chatGPTPreviousConversation, .chatGPTNextConversation:
            // Ignore held-button repeats while one navigation is awaiting readback.
            // A repeat must not display an error HUD over the target row.
            guard !chatGPTNavigationInFlight else { return }
            chatGPTNavigationInFlight = true
            hud.dismiss()
            Task { @MainActor in
                defer { chatGPTNavigationInFlight = false }
                let succeeded = await automation.navigateChatGPTSidebar(action)
                finish(action.label, succeeded: succeeded)
            }
        case .cursorPreviousConversation, .cursorNextConversation, .cursorCollapseWorkspace, .cursorExpandWorkspace:
            Task { @MainActor in
                let succeeded = await automation.navigateCursorConversation(action)
                finish(action.label, succeeded: succeeded)
            }
        case .grokPreviousBot, .grokNextBot, .grokCollapseSection, .grokExpandSection:
            Task { @MainActor in
                let succeeded = await automation.navigateGrokBot(action)
                finish(action.label, succeeded: succeeded)
            }
        case .showControllerOverlay:
            showControllerContext()
        case .deleteTextWithConfirmation:
            let deleted = automation.confirmDeleteFocusedText()
            lastAction = automation.lastResult
            if deleted {
                hud.show(String(localized: "Text deleted", bundle: AppResources.localizationBundle), color: .systemGreen)
                controller.playHaptic(.success)
            } else if automation.lastResult == String(localized: "Delete cancelled", bundle: AppResources.localizationBundle) {
                controller.playHaptic(.selection)
            } else {
                feedbackFailure(automation.lastResult)
            }
        default:
            finish(action.label, succeeded: automation.run(action))
        }
    }

    private func toggleUniversalDictation() {
        if generalDictationBackend == .sogouAssistant, profiles.activeKind != .claude {
            if sogouDictation.isActive { sogouDictation.stop() }
            else { handleSogouDictation(input: .microphone, pressed: true) }
            return
        }
        let initiator = universalDictationMode?.initiator ?? .microphone
        handleUniversalDictation(input: initiator, pressed: true)
        handleUniversalDictation(input: initiator, pressed: false)
    }

    var selectedTask: RecentCodexTask? {
        guard let selectedTaskID else { return nil }
        return recentTasks.first(where: { $0.id == selectedTaskID })
    }

    func selectTask(_ id: String) {
        guard let task = recentTasks.first(where: { $0.id == id }) else {
            return
        }
        selectedTaskID = id
        updateAggregateState()
        let succeeded = automation.openThread(id)
        lastAction = succeeded
            ? String(localized: "Selected · \(task.shortTitle)", bundle: AppResources.localizationBundle)
            : automation.lastResult
        if succeeded {
            hud.show(
                String(localized: "Selected task", bundle: AppResources.localizationBundle),
                detail: task.shortTitle,
                color: task.state.color
            )
            controller.playHaptic(.selection)
        } else {
            feedbackFailure(automation.lastResult)
        }
    }

    private func selectAdjacentTask(offset: Int) {
        guard let id = TaskSelection.adjacentID(
            in: recentTasks,
            selectedID: selectedTaskID,
            offset: offset
        ) else {
            finish(
                offset < 0 ? String(localized: "Previous task", bundle: AppResources.localizationBundle) : String(localized: "Next task", bundle: AppResources.localizationBundle),
                succeeded: automation.run(
                    offset < 0 ? .codexPreviousTask : .codexNextTask
                )
            )
            return
        }
        selectTask(id)
    }

    private func showControllerContext() {
        controllerOverlay.showContext(
            profile: profiles.activeProfile,
            task: overlayTask,
            profiles: profiles.profiles,
            slots: shiftLayer.profileSlots
        )
        lastAction = String(localized: "Controller overlay", bundle: AppResources.localizationBundle)
        controller.playHaptic(.selection)
    }

    private var overlayTask: ControllerOverlayTask? {
        selectedTask.map {
            ControllerOverlayTask(title: $0.shortTitle, state: $0.state)
        }
    }

    private func finish(_ label: String, succeeded: Bool) {
        lastAction = succeeded ? label : automation.lastResult
        if succeeded {
            hud.show(label, color: currentState.color)
            controller.playHaptic(.selection)
        } else {
            feedbackFailure(automation.lastResult)
        }
    }

    private func toggleVoiceCapture(initiator: ControllerInput?) {
        guard !voiceStopPending else {
            lastAction = String(localized: "Finishing the current dictation", bundle: AppResources.localizationBundle)
            return
        }
        if pushToTalkActive {
            setPushToTalk(false, handsFree: true)
        } else {
            setPushToTalk(
                true,
                handsFree: true,
                mode: .toggle(initiator)
            )
        }
    }

    private func setPushToTalk(
        _ active: Bool,
        handsFree: Bool = false,
        mode: VoiceCaptureMode? = nil
    ) {
        guard !voiceStopPending else { return }
        guard active != pushToTalkActive else { return }

        if active {
            // Game Controller will be gated while Bluetooth audio is flowing;
            // clear motion that would otherwise continue on an existing timer.
            pointer.stop()
            touchpad.cancel()
            let requestedTransport = controller.transport
            dictationFocusGuard.begin(
                targetApplication:
                    NSWorkspace.shared.frontmostApplication
            )
            if requestedTransport == .usb, audio.controllerAudioAvailable {
                lastAction = String(localized: "Preparing DualSense microphone", bundle: AppResources.localizationBundle)
                guard audio.ensureCodexMicrophone() else {
                    failNativeDictation(
                        audio.lastAudioResult,
                        transport: requestedTransport
                    )
                    return
                }
            } else if requestedTransport == .bluetooth {
                lastAction = String(localized: "Preparing Bluetooth DualSense microphone", bundle: AppResources.localizationBundle)
                audio.removeCodexMicrophone()
                guard bluetoothMicrophone.startCapture() else {
                    failNativeDictation(
                        bluetoothMicrophone.lastResult,
                        transport: requestedTransport
                    )
                    return
                }
                controller.reinforceSystemGestureSuppression()
                guard controller.setBluetoothMicrophoneCapture(true) else {
                    bluetoothMicrophone.stopCapture()
                    failNativeDictation(
                        controller.lastBluetoothMicrophoneResult,
                        transport: requestedTransport
                    )
                    return
                }
            }
            guard automation.startDictation() else {
                failNativeDictation(
                    automation.lastResult,
                    transport: requestedTransport
                )
                return
            }

            voiceCaptureTransport = requestedTransport
            voiceCaptureMode = mode ?? .toggle(nil)
            pushToTalkActive = true
            updateState(.listening)
            if requestedTransport == .usb {
                controller.setMicrophoneLED(.off)
            }
            controller.playHaptic(.listeningStart)
            playFeedbackSound(.listeningStart)
            lastAction = String(localized: "Codex is listening", bundle: AppResources.localizationBundle)
            hud.show(
                handsFree ? String(localized: "Hands-free Codex dictation", bundle: AppResources.localizationBundle) : String(localized: "Codex is listening", bundle: AppResources.localizationBundle),
                detail: requestedTransport == .bluetooth
                    ? String(localized: "Using the wireless DualSense Microphone input", bundle: AppResources.localizationBundle)
                    : requestedTransport == .usb
                        ? String(localized: "Using the selected DualSense Microphone input", bundle: AppResources.localizationBundle)
                        : String(localized: "Using Codex's selected Mac microphone", bundle: AppResources.localizationBundle),
                color: CodexTaskState.listening.color
            )
        } else {
            let completedTransport =
                voiceCaptureTransport ?? controller.transport
            pushToTalkActive = false
            voiceCaptureMode = nil
            voiceCaptureTransport = nil
            controller.playHaptic(.listeningStop)
            playFeedbackSound(.listeningStop)
            if completedTransport == .bluetooth,
               controller.transport == .bluetooth,
               bluetoothMicrophone.isCapturing {
                beginBluetoothVoiceStop()
                return
            }
            guard automation.stopDictationAndInsert() else {
                failNativeDictation(
                    automation.lastResult,
                    transport: completedTransport
                )
                return
            }
            stopVoiceCaptureResources(for: completedTransport)
            dictationFocusGuard.end()
            showTranscribingState()
        }
    }

    private func beginBluetoothVoiceStop() {
        voiceStopGeneration += 1
        let generation = voiceStopGeneration
        voiceStopPending = true

        // Stop the HID uplink first, but leave the decoder and AVAudioSourceNode
        // alive long enough to render the 50 ms jitter buffer and final packet.
        _ = controller.setBluetoothMicrophoneCapture(false)
        lastAction = String(localized: "Finishing Bluetooth dictation", bundle: AppResources.localizationBundle)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            [weak self] in
            guard let self,
                  self.voiceStopPending,
                  self.voiceStopGeneration == generation
            else {
                return
            }
            self.voiceStopPending = false
            let stopped = self.automation.stopDictationAndInsert()
            self.bluetoothMicrophone.stopCapture()
            self.dictationFocusGuard.end()
            guard stopped else {
                self.feedbackFailure(self.automation.lastResult)
                self.updateAggregateState()
                return
            }
            self.showTranscribingState()
        }
    }

    private func showTranscribingState() {
        updateState(.processingVoice)
        lastAction = String(localized: "Codex is transcribing", bundle: AppResources.localizationBundle)
        hud.show(
            String(localized: "Codex is transcribing", bundle: AppResources.localizationBundle),
            detail: String(localized: "Using Codex's native transcription", bundle: AppResources.localizationBundle),
            color: .white
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            [weak self] in
            self?.updateAggregateState()
        }
    }

    private func completeSelfTest(
        generation: Int,
        result: String? = nil
    ) {
        guard selfTestRunning, selfTestGeneration == generation else {
            return
        }
        selfTestRunning = false
        lastAction = result ?? String(localized: "Safe hardware self-test complete", bundle: AppResources.localizationBundle)
        hud.show(
            String(localized: "Self-test complete", bundle: AppResources.localizationBundle),
            detail: result ?? String(localized: "One haptic and one speaker tone completed", bundle: AppResources.localizationBundle),
            color: .systemGreen
        )
        updateAggregateState()
    }

    private func completeWirelessMicrophoneDiagnostic(generation: Int) {
        guard microphoneDiagnosticRunning,
              microphoneDiagnosticGeneration == generation
        else {
            return
        }
        let packets = bluetoothMicrophone.receivedPacketCount
        let frames = bluetoothMicrophone.decodedFrameCount
        let peak = bluetoothMicrophone.peakInputLevel
        bluetoothMicrophone.stopCapture()
        microphoneDiagnosticRunning = false

        microphoneDiagnosticPassed = packets > 0 && frames > 0
        if microphoneDiagnosticPassed {
            let percent = Int((peak * 100).rounded())
            microphoneDiagnosticResult =
                String(localized: "Passed · \(packets) packets · voice peak \(percent)%", bundle: AppResources.localizationBundle)
            lastAction =
                String(localized: "Wireless mic passed: \(packets) packets, peak \(percent)%", bundle: AppResources.localizationBundle)
            hud.show(
                String(localized: "Wireless microphone works", bundle: AppResources.localizationBundle),
                detail: String(localized: "\(packets) packets decoded · peak \(percent)%", bundle: AppResources.localizationBundle),
                color: .systemGreen
            )
        } else {
            microphoneDiagnosticResult =
                String(localized: "Failed · no usable Bluetooth audio was received", bundle: AppResources.localizationBundle)
            feedbackFailure(
                String(localized: "No usable Bluetooth microphone audio was received", bundle: AppResources.localizationBundle)
            )
        }
    }

    private func failNativeDictation(
        _ message: String,
        transport: ControllerTransport? = nil
    ) {
        let failedTransport =
            transport ?? voiceCaptureTransport ?? controller.transport
        pushToTalkActive = false
        voiceCaptureMode = nil
        voiceCaptureTransport = nil
        stopVoiceCaptureResources(for: failedTransport)
        dictationFocusGuard.end()
        feedbackFailure(message)
        updateAggregateState()
    }

    private func controllerTransportChanged(_ transport: ControllerTransport) {
        pointer.stop()
        sogouDictation.stop()
        endAssistantDictationHold()
        appSwitcherSafetyGeneration += 1
        appSwitcherStick.reset()
        if appSwitcherHold.cancel() {
            _ = automation.cancelAppSwitcher()
        }
        if (universalDictationActive ||
                universalTranscriptionStopPending),
           let capturedTransport = universalDictationTransport,
           capturedTransport != transport {
            cancelUniversalTranscription(
                reason: String(localized: "Controller connection changed", bundle: AppResources.localizationBundle)
            )
        }
        if selfTestRunning {
            selfTestGeneration += 1
            selfTestRunning = false
            lastAction = String(localized: "Hardware self-test cancelled after connection change", bundle: AppResources.localizationBundle)
        }
        if microphoneDiagnosticRunning, transport != .bluetooth {
            microphoneDiagnosticGeneration += 1
            microphoneDiagnosticRunning = false
            bluetoothMicrophone.stopCapture()
            lastAction = String(localized: "Wireless microphone test cancelled after disconnect", bundle: AppResources.localizationBundle)
        }
        if pushToTalkActive,
           let capturedTransport = voiceCaptureTransport,
           capturedTransport != transport {
            cancelActiveVoiceCapture(
                capturedTransport: capturedTransport,
                reason: String(localized: "Controller connection changed", bundle: AppResources.localizationBundle)
            )
        }

        switch transport {
        case .usb:
            bluetoothMicrophone.teardown()
            audio.refresh()
            if audio.controllerAudioAvailable {
                _ = audio.ensureCodexMicrophone()
            }
        case .bluetooth:
            audio.removeCodexMicrophone()
            if bluetoothMicrophone.prepare() {
                lastAction = String(localized: "Wireless DualSense Microphone is ready", bundle: AppResources.localizationBundle)
            } else {
                lastAction = bluetoothMicrophone.lastResult
            }
        case .unknown:
            bluetoothMicrophone.teardown()
            audio.removeCodexMicrophone()
        }
        logger.notice(
            "Controller transport changed to \(transport.rawValue, privacy: .public)"
        )
    }

    private func isVoiceStopEvent(_ event: ControllerEvent) -> Bool {
        guard case let .button(input, pressed) = event
        else {
            return false
        }
        if sogouDictation.isActive { return input == sogouDictationInput && !pressed }
        if universalDictationActive {
            if input == .microphone, pressed {
                return true
            }
            switch universalDictationMode {
            case let .pendingTapOrHold(initiator):
                return input == initiator && !pressed
            case let .hold(initiator):
                return input == initiator && !pressed
            case let .toggle(initiator):
                return input == initiator && pressed
            case nil:
                return false
            }
        }
        guard pushToTalkActive else { return false }
        if input == .microphone, pressed {
            return true
        }
        switch voiceCaptureMode {
        case let .pendingTapOrHold(initiator):
            return input == initiator && !pressed
        case let .hold(initiator):
            return input == initiator && !pressed
        case let .toggle(initiator):
            return input == initiator && pressed
        case nil:
            return false
        }
    }

    private func stopVoiceCaptureResources(
        for transport: ControllerTransport
    ) {
        switch transport {
        case .usb:
            if controller.transport == .usb {
                controller.setMicrophoneLED(.on)
            }
        case .bluetooth:
            if controller.transport == .bluetooth {
                _ = controller.setBluetoothMicrophoneCapture(false)
            }
            bluetoothMicrophone.stopCapture()
        case .unknown:
            break
        }
    }

    private func cancelActiveVoiceCapture(
        capturedTransport: ControllerTransport,
        reason: String
    ) {
        guard pushToTalkActive else { return }
        pushToTalkActive = false
        voiceCaptureMode = nil
        voiceCaptureTransport = nil
        stopVoiceCaptureResources(for: capturedTransport)
        dictationFocusGuard.end()
        let stopped = automation.stopDictationAndInsert()
        lastAction = stopped
            ? String(localized: "\(reason); dictation stopped", bundle: AppResources.localizationBundle)
            : "\(reason); \(automation.lastResult)"
        updateAggregateState()
        logger.error(
            "Cancelled dictation after transport change from \(capturedTransport.rawValue, privacy: .public); automationStopped=\(stopped, privacy: .public)"
        )
    }

    private func cancelUniversalTranscription(reason: String) {
        guard universalDictationActive ||
                universalTranscriptionStopPending ||
                universalDictationTransport != nil
        else { return }
        universalTranscriptionSessionGeneration += 1
        universalDictationGeneration += 1
        universalDictationActive = false
        universalDictationMode = nil
        universalDictationPressed = false
        universalTranscriberReady = false
        universalTranscriptionStopPending = false
        if let transport = universalDictationTransport {
            stopVoiceCaptureResources(for: transport)
        }
        universalDictationTransport = nil
        if universalDictationProvider == .claudeNative {
            _ = automation.stopClaudeDictation()
        } else if universalDictationProvider == .localSpeech {
            localSpeechTranscriber.cancel()
        } else {
            _ = appleSpeechTranscriber.cancel()
        }
        universalDictationProvider = nil
        dictationFocusGuard.end()
        hud.dismiss()
        lastAction = String(localized: "\(reason); transcription stopped", bundle: AppResources.localizationBundle)
        updateAggregateState()
    }

    private func shutdown() {
        pointer.stop()
        sogouDictation.stopBeforeExit()
        if let transport = sogouDictationTransport { stopVoiceCaptureResources(for: transport) }
        caretNeutralTimer?.invalidate()
        caretNeutralTimer = nil
        if let caretApplicationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(caretApplicationObserver)
            self.caretApplicationObserver = nil
        }
        voiceStopGeneration += 1
        universalDictationGeneration += 1
        selfTestGeneration += 1
        microphoneDiagnosticGeneration += 1
        selfTestRunning = false
        microphoneDiagnosticRunning = false
        if voiceStopPending {
            voiceStopPending = false
            _ = automation.stopDictationAndInsert()
            if controller.transport == .bluetooth {
                _ = controller.setBluetoothMicrophoneCapture(false)
            }
            bluetoothMicrophone.stopCapture()
        }
        if pushToTalkActive {
            cancelActiveVoiceCapture(
                capturedTransport:
                    voiceCaptureTransport ?? controller.transport,
                reason: String(localized: "ControlDeck is closing", bundle: AppResources.localizationBundle)
            )
        }
        if universalDictationActive ||
            universalTranscriptionStopPending {
            cancelUniversalTranscription(reason: String(localized: "ControlDeck is closing", bundle: AppResources.localizationBundle))
        }
        appSwitcherSafetyGeneration += 1
        appSwitcherStick.reset()
        if appSwitcherHold.cancel() {
            _ = automation.cancelAppSwitcher()
        }
        endAssistantDictationHold()
        controller.stop()
        dictationFocusGuard.end()
        bluetoothMicrophone.teardown()
        audio.removeCodexMicrophone()
    }

    private func tasksChanged(_ tasks: [RecentCodexTask]) {
        let previous = lastStates
        recentTasks = tasks
        if !tasks.contains(where: { $0.id == selectedTaskID }) {
            selectedTaskID = tasks.first?.id
        }
        lastStates = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.state) })
        updateAggregateState()

        for task in tasks {
            guard let old = previous[task.id], old != task.state else { continue }
            switch task.state {
            case .complete:
                if statusHaptics {
                    controller.playHaptic(.success)
                }
                hud.show(String(localized: "Task complete", bundle: AppResources.localizationBundle), detail: task.shortTitle, color: task.state.color)
                playFeedbackSound(.complete)
            case .needsInput:
                if statusHaptics {
                    controller.playHaptic(.warning)
                }
                hud.show(String(localized: "Task needs input", bundle: AppResources.localizationBundle), detail: task.shortTitle, color: task.state.color)
                playFeedbackSound(.needsInput)
            case .error:
                if statusHaptics {
                    controller.playHaptic(.error)
                }
                hud.show(String(localized: "Task error", bundle: AppResources.localizationBundle), detail: task.shortTitle, color: task.state.color)
                playFeedbackSound(.error)
            default:
                break
            }
        }
    }

    private func updateAggregateState() {
        guard !pushToTalkActive,
              !voiceStopPending,
              !universalTranscriptionStopPending
        else { return }
        updateState(
            selectedTask?.state ??
                CodexTaskState.aggregate(recentTasks.map(\.state))
        )
    }

    private func updateState(_ state: CodexTaskState) {
        currentState = controller.isConnected ? state : .disconnected
        controller.setState(currentState)
    }

    private func feedbackFailure(_ message: String) {
        lastAction = message
        controller.playHaptic(.error)
        hud.show(String(localized: "Action unavailable", bundle: AppResources.localizationBundle), detail: message, color: .systemRed)
    }

    func previewSoundTheme() {
        playFeedbackSound(.complete)
    }

    private func playFeedbackSound(_ cue: FeedbackSoundCue) {
        let tones = soundTheme.tones(for: cue)
        guard !tones.isEmpty, controller.isConnected else { return }
        soundGeneration += 1
        playFeedbackTone(
            tones,
            index: 0,
            generation: soundGeneration
        )
    }

    private func playFeedbackTone(
        _ tones: [FeedbackTone],
        index: Int,
        generation: Int
    ) {
        guard generation == soundGeneration, tones.indices.contains(index)
        else {
            return
        }
        let tone = tones[index]
        let next = { [weak self] in
            guard let self else { return }
            DispatchQueue.main.asyncAfter(
                deadline: .now() + tone.pauseAfter
            ) {
                self.playFeedbackTone(
                    tones,
                    index: index + 1,
                    generation: generation
                )
            }
        }
        if controller.transport == .bluetooth {
            _ = controller.playBluetoothSpeakerTone(
                frequency: tone.frequency,
                duration: tone.duration,
                volume: tone.volume
            ) { _ in
                next()
            }
        } else if controller.transport == .usb {
            guard audio.playControllerTone(
                frequency: tone.frequency,
                duration: tone.duration,
                volume: tone.volume
            ) else {
                return
            }
            DispatchQueue.main.asyncAfter(
                deadline: .now() + tone.duration
            ) {
                next()
            }
        }
    }
}

private enum VoiceCaptureMode: Equatable {
    case pendingTapOrHold(ControllerInput)
    case hold(ControllerInput)
    case toggle(ControllerInput?)

    var initiator: ControllerInput? {
        switch self {
        case let .pendingTapOrHold(input), let .hold(input):
            input
        case let .toggle(input):
            input
        }
    }
}

private enum UniversalDictationProvider {
    case appleSpeech
    case localSpeech
    case claudeNative
}
