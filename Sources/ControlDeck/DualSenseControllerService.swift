import AppKit
import CoreHaptics
import Foundation
import GameController
import OSLog

@MainActor
final class DualSenseControllerService: ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var batteryLevel: Float = 0
    @Published private(set) var batteryState = "Unknown"
    @Published private(set) var lastInput = String(localized: "Waiting for controller", bundle: AppResources.localizationBundle)
    @Published private(set) var transport: ControllerTransport = .unknown
    private(set) var activeTouchCount = 0
    @Published private(set) var controllerFamily: ControllerFamily = .dualSense
    @Published private(set) var controllerName = "DualSense"
    @Published private(set) var motionAvailable = false

    var isCharging: Bool { batteryState == "Charging" }

    var onEvent: ((ControllerEvent) -> Void)?
    var onBluetoothMicrophonePacket:
        ((DualSenseBluetoothMicrophonePacket) -> Void)?
    var onBluetoothMicrophoneRecoveryRequired: ((String) -> Void)?
    var onTransportChanged: ((ControllerTransport) -> Void)?

    private var controller: GCController?
    private var hapticEngine: CHHapticEngine?
    private var notificationTokens: [NSObjectProtocol] = []
    private var pulseTimer: Timer?
    private var batteryTimer: Timer?
    private var pulsePhase: Double = 0
    private var displayedState: CodexTaskState = .disconnected
    private var leftTriggerActive = false
    private var rightTriggerFired = false
    private var primaryTouchActive = false
    private var secondaryTouchActive = false
    private let hidService = DualSenseHIDService()
    private let microphoneInputGate = BluetoothMicrophoneInputGate()
    private var microphoneDrainGeneration = 0
    private var speakerInputProtectionActive = false
    private var speakerPlaybackActive = false
    private var speakerCompletion: ((String) -> Void)?
    private var motionSensorsRequested = true
    private var motionNormalizer = ControllerMotionNormalizer()
    private let logger = Logger(subsystem: "com.ianhansel.controldeck", category: "controller")

    init() {
        let inputGate = microphoneInputGate
        hidService.onRawButtonChanged = { [weak self, inputGate] input, pressed in
            guard input == .microphone || inputGate.isSuppressed else { return }
            Task { @MainActor in
                if pressed {
                    self?.lastInput = input.label
                }
                self?.onEvent?(.button(input, pressed: pressed))
            }
        }
        hidService.onBluetoothControlReport = { [weak self, inputGate] leftTrigger in
            inputGate.noteControlReport()
            guard inputGate.isSuppressed else { return }
            Task { @MainActor in
                self?.handleRawLeftTrigger(leftTrigger)
            }
        }
        hidService.onBluetoothMicrophonePacket = { [weak self, inputGate] packet in
            inputGate.noteAudioPacket()
            self?.onBluetoothMicrophonePacket?(packet)
        }
        hidService.onBluetoothSpeakerResult = { [weak self] result in
            Task { @MainActor in
                self?.speakerPlaybackActive = false
                if self?.speakerInputProtectionActive == true {
                    self?.speakerInputProtectionActive = false
                    if self?.transport == .bluetooth {
                        _ = self?.setBluetoothMicrophoneCapture(false)
                    } else {
                        self?.microphoneInputGate.forceOpen()
                    }
                }
                self?.lastInput = result
                let completion = self?.speakerCompletion
                self?.speakerCompletion = nil
                completion?(result)
            }
        }
        hidService.onTransportChanged = { [weak self] transport in
            Task { @MainActor in
                if transport != .bluetooth {
                    self?.microphoneDrainGeneration += 1
                    self?.speakerInputProtectionActive = false
                    self?.speakerPlaybackActive = false
                    self?.speakerCompletion = nil
                    self?.microphoneInputGate.forceOpen()
                }
                self?.transport = transport
                self?.onTransportChanged?(transport)
            }
        }
    }

    deinit {
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
    }

    func start() {
        guard notificationTokens.isEmpty else { return }
        GCController.shouldMonitorBackgroundEvents = true

        notificationTokens.append(
            NotificationCenter.default.addObserver(
                forName: .GCControllerDidConnect,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let connected = notification.object as? GCController else { return }
                Task { @MainActor in self?.connect(connected) }
            }
        )
        notificationTokens.append(
            NotificationCenter.default.addObserver(
                forName: .GCControllerDidDisconnect,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let disconnected = notification.object as? GCController else { return }
                Task { @MainActor in
                    if self?.controller === disconnected { self?.disconnect() }
                }
            }
        )

        // Controller mappings can change while the app is backgrounded.
        // Reapply our preference when returning and after user customization.
        notificationTokens.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.reinforceSystemGestureSuppression() }
            }
        )
        notificationTokens.append(
            NotificationCenter.default.addObserver(
                forName: .GCControllerUserCustomizationsDidChange,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let customized = notification.object as? GCController else { return }
                Task { @MainActor in
                    guard self?.controller === customized else { return }
                    self?.reinforceSystemGestureSuppression()
                }
            }
        )

        hidService.start()
        GCController.startWirelessControllerDiscovery {
            // Paired DualSense controllers connect through the same
            // GCControllerDidConnect notification used by wired controllers.
        }
        if let existing = GCController.controllers().first(
            where: { $0.extendedGamepad != nil }
        ) {
            connect(existing)
        }
    }

    func stop() {
        microphoneDrainGeneration += 1
        speakerInputProtectionActive = false
        speakerPlaybackActive = false
        speakerCompletion = nil
        if transport == .bluetooth, microphoneInputGate.isSuppressed {
            _ = hidService.setBluetoothMicrophoneCapture(false)
        }
        microphoneInputGate.forceOpen()
        hidService.stop()
        GCController.stopWirelessControllerDiscovery()
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        notificationTokens.removeAll()
        disconnect()
    }

    func setState(_ state: CodexTaskState) {
        displayedState = state
        updateLight()
        configurePulseTimer(for: state)
    }

    func setMotionSensorsActive(_ active: Bool) {
        motionSensorsRequested = active
        guard let motion = controller?.motion,
              motion.sensorsRequireManualActivation
        else { return }
        motion.sensorsActive = active
    }

    func playHaptic(_ cue: HapticCue) {
        guard let hapticEngine else { return }

        let events: [CHHapticEvent]
        switch cue {
        case .connect:
            events = [
                transient(at: 0, intensity: 0.45, sharpness: 0.35),
                transient(at: 0.12, intensity: 0.7, sharpness: 0.55)
            ]
        case .success:
            events = [
                transient(at: 0, intensity: 0.24, sharpness: 0.28),
                transient(at: 0.08, intensity: 0.36, sharpness: 0.58)
            ]
        case .selection:
            events = [transient(at: 0, intensity: 0.28, sharpness: 0.75)]
        case .warning:
            events = [
                transient(at: 0, intensity: 0.32, sharpness: 0.25),
                transient(at: 0.14, intensity: 0.32, sharpness: 0.25)
            ]
        case .error:
            events = [
                transient(at: 0, intensity: 0.40, sharpness: 0.14),
                transient(at: 0.12, intensity: 0.40, sharpness: 0.14)
            ]
        case .listeningStart:
            events = [
                continuous(at: 0, duration: 0.18, intensity: 0.35, sharpness: 0.2),
                transient(at: 0.19, intensity: 0.55, sharpness: 0.6)
            ]
        case .listeningStop:
            events = [
                transient(at: 0, intensity: 0.45, sharpness: 0.55),
                continuous(at: 0.05, duration: 0.12, intensity: 0.22, sharpness: 0.1)
            ]
        }

        do {
            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try hapticEngine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            lastInput = String(localized: "Haptic error: \(error.localizedDescription)", bundle: AppResources.localizationBundle)
        }
    }

    func setMicrophoneLED(_ state: MicrophoneLEDState) {
        _ = hidService.setMicrophoneLED(state)
    }

    @discardableResult
    func setBluetoothMicrophoneCapture(_ active: Bool) -> Bool {
        microphoneDrainGeneration += 1
        let generation = microphoneDrainGeneration
        if active {
            reinforceSystemGestureSuppression()
            quiesceTransientInputForMicrophone()
            microphoneInputGate.beginCapture()
            let opened = hidService.setBluetoothMicrophoneCapture(true)
            if !opened {
                microphoneInputGate.forceOpen()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    [weak self] in
                    guard let self,
                          self.microphoneDrainGeneration == generation,
                          self.microphoneInputGate.isSuppressed
                    else { return }
                    self.reinforceSystemGestureSuppression()
                }
            }
            return opened
        }

        microphoneInputGate.beginDrain()
        let closed = hidService.setBluetoothMicrophoneCapture(false)
        scheduleMicrophoneDrainChecks(generation: generation)
        return closed
    }

    /// Request direct input delivery again after lifecycle or profile changes.
    /// Apple's API documents this as a preference, not guaranteed suppression;
    /// background event monitoring does not grant exclusive controller access.
    func reinforceSystemGestureSuppression() {
        guard let controller else { return }
        for element in controller.physicalInputProfile.allElements {
            element.preferredSystemGestureState = .disabled
        }
        if let gamepad = controller.extendedGamepad {
            for element in gamepad.allElements {
                element.preferredSystemGestureState = .disabled
            }
        }
    }

    var lastBluetoothMicrophoneResult: String {
        hidService.lastBluetoothMicrophoneResult
    }

    var lastBluetoothSpeakerResult: String {
        hidService.lastBluetoothSpeakerResult
    }

    var isBluetoothMicrophoneInputSuppressed: Bool {
        microphoneInputGate.isSuppressed
    }

    @discardableResult
    func playBluetoothSpeakerTone(
        frequency: Float = 740,
        duration: TimeInterval = 0.18,
        volume: Float = 0.12,
        completion: ((String) -> Void)? = nil
    ) -> Bool {
        guard !speakerPlaybackActive else {
            lastInput = String(localized: "A controller speaker cue is already playing", bundle: AppResources.localizationBundle)
            return false
        }
        speakerPlaybackActive = true
        speakerCompletion = completion
        if !microphoneInputGate.isSuppressed {
            quiesceTransientInputForMicrophone()
            microphoneInputGate.beginCapture()
            speakerInputProtectionActive = true
        }
        let started = hidService.playBluetoothSpeakerTone(
            frequency: frequency,
            duration: duration,
            volume: volume
        )
        if !started, speakerInputProtectionActive {
            speakerInputProtectionActive = false
            microphoneInputGate.forceOpen()
        }
        if !started {
            speakerPlaybackActive = false
            speakerCompletion = nil
        }
        return started
    }

    func runSafeHapticSelfTest(completion: @escaping () -> Void) {
        guard isConnected else {
            completion()
            return
        }
        // One short, low-intensity event is enough to prove haptic output.
        // The self-test deliberately does not alter triggers, lights or mic
        // state, and never overlaps multiple feedback operations.
        playHaptic(.selection)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            completion()
        }
    }

    private func connect(_ controller: GCController) {
        guard let gamepad = controller.extendedGamepad else { return }
        self.controller = controller
        controllerFamily = ControllerFamily.identify(
            vendorName: controller.vendorName,
            productCategory: controller.productCategory
        )
        if gamepad is GCDualSenseGamepad {
            controllerFamily = .dualSense
        }
        controllerName = controller.vendorName ?? controllerFamily.label
        isConnected = true
        lastInput = String(localized: "\(controllerName) connected", bundle: AppResources.localizationBundle)
        batteryLevel = controller.battery?.batteryLevel ?? 0
        batteryState = describeBattery(controller.battery?.batteryState)
        batteryTimer?.invalidate()
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshBattery() }
        }
        configure(gamepad)
        configureMotion(controller)
        configureHaptics(controller)
        if controllerFamily.isDualSense {
            configureAdaptiveTriggers()
        }
        setState(.idle)
        if controllerFamily.isDualSense {
            setMicrophoneLED(.on)
        }
        playHaptic(.connect)
        logger.notice(
            "\(self.controllerName, privacy: .public) connected; family=\(self.controllerFamily.rawValue, privacy: .public) light=\(controller.light != nil) haptics=\(controller.haptics != nil) motion=\(self.motionAvailable) battery=\(controller.battery != nil)"
        )
    }

    private func disconnect() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        batteryTimer?.invalidate()
        batteryTimer = nil
        hapticEngine?.stop(completionHandler: nil)
        hapticEngine = nil
        motionNormalizer.reset()
        controller?.motion?.valueChangedHandler = nil
        if controller?.motion?.sensorsRequireManualActivation == true {
            controller?.motion?.sensorsActive = false
        }
        controller = nil
        isConnected = false
        displayedState = .disconnected
        lastInput = String(localized: "DualSense disconnected", bundle: AppResources.localizationBundle)
        batteryLevel = 0
        batteryState = "Disconnected"
        leftTriggerActive = false
        rightTriggerFired = false
        primaryTouchActive = false
        secondaryTouchActive = false
        activeTouchCount = 0
        controllerName = "DualSense"
        controllerFamily = .dualSense
        motionAvailable = false
        logger.notice("DualSense disconnected")
    }

    private func configure(_ gamepad: GCExtendedGamepad) {
        // Request suppression for all mapped elements, including L2/R2.
        // macOS can still override this preference for system shortcuts.
        for element in gamepad.allElements {
            element.preferredSystemGestureState = .disabled
        }
        reinforceSystemGestureSuppression()

        bind(gamepad.buttonA, name: "Cross", input: .cross)
        bind(gamepad.buttonB, name: "Circle", input: .circle)
        bind(gamepad.buttonX, name: "Square", input: .square)
        bind(gamepad.buttonY, name: "Triangle", input: .triangle)
        bind(gamepad.leftShoulder, name: "L1", input: .l1)
        bind(gamepad.rightShoulder, name: "R1", input: .r1)
        bind(gamepad.buttonMenu, name: "Options", input: .options)
        if let options = gamepad.buttonOptions {
            bind(options, name: "Create", input: .create)
        }
        if let leftThumbstickButton = gamepad.leftThumbstickButton {
            bind(leftThumbstickButton, name: "L3", input: .l3)
        }
        if let rightThumbstickButton = gamepad.rightThumbstickButton {
            bind(rightThumbstickButton, name: "R3", input: .r3)
        }
        if let home = gamepad.buttonHome {
            bind(home, name: "PS", input: .ps)
        }

        bind(gamepad.dpad.up, name: String(localized: "D-pad up", bundle: AppResources.localizationBundle), input: .dpadUp)
        bind(gamepad.dpad.right, name: String(localized: "D-pad right", bundle: AppResources.localizationBundle), input: .dpadRight)
        bind(gamepad.dpad.down, name: String(localized: "D-pad down", bundle: AppResources.localizationBundle), input: .dpadDown)
        bind(gamepad.dpad.left, name: String(localized: "D-pad left", bundle: AppResources.localizationBundle), input: .dpadLeft)

        let inputGate = microphoneInputGate
        gamepad.leftTrigger.valueChangedHandler = { [weak self, inputGate] _, value, _ in
            guard inputGate.acceptsGameControllerInput else { return }
            Task { @MainActor in self?.handleLeftTrigger(value) }
        }
        gamepad.rightTrigger.valueChangedHandler = { [weak self, inputGate] _, value, _ in
            guard inputGate.acceptsGameControllerInput else { return }
            Task { @MainActor in self?.handleRightTrigger(value) }
        }
        if let dualSense = gamepad as? GCDualSenseGamepad {
            dualSense.touchpadPrimary.valueChangedHandler = {
                [weak self, inputGate] _, x, y in
                guard inputGate.acceptsGameControllerInput else { return }
                Task { @MainActor in
                    self?.handleTouch(finger: .primary, x: x, y: y)
                }
            }
            dualSense.touchpadSecondary.valueChangedHandler = {
                [weak self, inputGate] _, x, y in
                guard inputGate.acceptsGameControllerInput else { return }
                Task { @MainActor in
                    self?.handleTouch(finger: .secondary, x: x, y: y)
                }
            }
            dualSense.touchpadButton.valueChangedHandler = {
                [weak self, inputGate] _, _, pressed in
                guard inputGate.acceptsGameControllerInput else { return }
                Task { @MainActor in
                    self?.lastInput = String(localized: "Touchpad click", bundle: AppResources.localizationBundle)
                    self?.onEvent?(
                        .button(.touchpadClick, pressed: pressed)
                    )
                }
            }
        }
        gamepad.leftThumbstick.valueChangedHandler = { [weak self, inputGate] _, x, y in
            guard inputGate.acceptsGameControllerInput else { return }
            Task { @MainActor in
                self?.onEvent?(.stick(.left, x: x, y: y))
            }
        }
        gamepad.rightThumbstick.valueChangedHandler = { [weak self, inputGate] _, x, y in
            guard inputGate.acceptsGameControllerInput else { return }
            Task { @MainActor in
                self?.onEvent?(.stick(.right, x: x, y: y))
            }
        }
    }

    private func configureMotion(_ controller: GCController) {
        motionNormalizer.reset()
        guard let motion = controller.motion else {
            motionAvailable = false
            return
        }
        motionAvailable = true
        if motion.sensorsRequireManualActivation {
            motion.sensorsActive = motionSensorsRequested
        }
        logger.notice(
            "Motion configured; separateGravity=\(motion.hasGravityAndUserAcceleration) manualActivation=\(motion.sensorsRequireManualActivation) sensorsActive=\(motion.sensorsActive)"
        )
        let inputGate = microphoneInputGate
        motion.valueChangedHandler = { [weak self, inputGate] motion in
            guard inputGate.acceptsGameControllerInput else { return }
            let gravity = motion.gravity
            let userAcceleration = motion.userAcceleration
            let totalAcceleration = motion.acceleration
            let rotation = motion.rotationRate
            let raw = RawControllerMotionSample(
                reportedGravityX: gravity.x,
                reportedGravityY: gravity.y,
                reportedGravityZ: gravity.z,
                reportedUserAccelerationX: userAcceleration.x,
                reportedUserAccelerationY: userAcceleration.y,
                reportedUserAccelerationZ: userAcceleration.z,
                totalAccelerationX: totalAcceleration.x,
                totalAccelerationY: totalAcceleration.y,
                totalAccelerationZ: totalAcceleration.z,
                rotationX: rotation.x,
                rotationY: rotation.y,
                rotationZ: rotation.z,
                hasSeparateGravity: motion.hasGravityAndUserAcceleration,
                timestamp: ProcessInfo.processInfo.systemUptime
            )
            Task { @MainActor in
                self?.handleMotionReading(raw)
            }
        }
    }

    private func handleMotionReading(_ raw: RawControllerMotionSample) {
        let sample = motionNormalizer.normalize(raw)
        onEvent?(.motion(sample))
    }

    private func bind(
        _ button: GCControllerButtonInput,
        name: String,
        input: ControllerInput
    ) {
        // `alwaysReceive` lets the app and macOS act on the same press. On the
        // PS/Home button that can launch Apple Games while ControlDeck is also
        // focusing Codex. ControlDeck is a background input utility, so take
        // full ownership of mapped buttons while it is running.
        button.preferredSystemGestureState = .disabled
        let inputGate = microphoneInputGate
        button.valueChangedHandler = { [weak self, inputGate] _, _, pressed in
            guard inputGate.acceptsGameControllerInput else { return }
            Task { @MainActor in
                if pressed {
                    self?.lastInput = name
                }
                self?.onEvent?(.button(input, pressed: pressed))
            }
        }
    }

    private func handleRawLeftTrigger(_ value: Float) {
        // Raw, validated type-1 control reports remain safe while Game
        // Controller input is suppressed. They provide the release event that
        // ends L2 push-to-talk without interpreting Opus bytes as controls.
        if value >= 0.55, !leftTriggerActive {
            leftTriggerActive = true
            onEvent?(.button(.l2, pressed: true))
        } else if value <= 0.2, leftTriggerActive {
            leftTriggerActive = false
            onEvent?(.button(.l2, pressed: false))
        }
    }

    private func scheduleMicrophoneDrainChecks(generation: Int) {
        let checkpoints: [(delay: TimeInterval, retry: Bool)] = [
            (0.10, true),
            (0.25, true),
            (0.50, false)
        ]
        for checkpoint in checkpoints {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + checkpoint.delay
            ) { [weak self] in
                guard let self,
                      self.microphoneDrainGeneration == generation,
                      self.microphoneInputGate.isSuppressed
                else {
                    return
                }
                if self.microphoneInputGate.finishDrainIfQuiet(
                    minimumSilence: 0.095
                ) {
                    self.quiesceTransientInputForMicrophone()
                    self.logger.notice(
                        "Bluetooth microphone stream closed and controller input resumed"
                    )
                    return
                }
                if checkpoint.retry {
                    _ = self.hidService.setBluetoothMicrophoneCapture(false)
                    return
                }

                let message =
                    String(localized: "Wireless microphone did not close safely; reconnect the controller", bundle: AppResources.localizationBundle)
                self.logger.error("\(message, privacy: .public)")
                self.onBluetoothMicrophoneRecoveryRequired?(message)
                // Deliberately remain suppressed. Exposing Game Controller
                // input while type-2 audio is still flowing creates phantom
                // buttons, sticks and pointer movement.
            }
        }
    }

    private func quiesceTransientInputForMicrophone() {
        // Keep leftTriggerActive so a raw L2 release can end push-to-talk.
        // All other transient state must be neutral while Game Controller
        // callbacks are gated, otherwise a prior touch/trigger can remain
        // logically active until an event that the gate intentionally drops.
        rightTriggerFired = false
        primaryTouchActive = false
        secondaryTouchActive = false
        activeTouchCount = 0
    }

    private func handleLeftTrigger(_ value: Float) {
        if value >= 0.55 && !leftTriggerActive {
            leftTriggerActive = true
            lastInput = String(localized: "L2", bundle: AppResources.localizationBundle)
            onEvent?(.button(.l2, pressed: true))
        } else if value <= 0.2 && leftTriggerActive {
            leftTriggerActive = false
            onEvent?(.button(.l2, pressed: false))
        }
    }

    private func handleRightTrigger(_ value: Float) {
        // Fire just past the adaptive-trigger resistance point. Requiring a
        // near-bottomed-out pull made screenshot selection feel intermittent.
        if value >= 0.7 && !rightTriggerFired {
            rightTriggerFired = true
            lastInput = String(localized: "R2", bundle: AppResources.localizationBundle)
            onEvent?(.button(.r2, pressed: true))
        } else if value <= 0.3 {
            if rightTriggerFired {
                onEvent?(.button(.r2, pressed: false))
            }
            rightTriggerFired = false
        }
    }

    private func handleTouch(
        finger: TouchFinger,
        x: Float,
        y: Float
    ) {
        let active = abs(x) > 0.002 || abs(y) > 0.002
        switch finger {
        case .primary: primaryTouchActive = active
        case .secondary: secondaryTouchActive = active
        }
        activeTouchCount =
            (primaryTouchActive ? 1 : 0) + (secondaryTouchActive ? 1 : 0)
        onEvent?(.touch(finger, x: x, y: y, active: active))
    }

    private func configureHaptics(_ controller: GCController) {
        guard let haptics = controller.haptics,
              let engine = haptics.createEngine(withLocality: .default)
        else { return }
        hapticEngine = engine
        do {
            try engine.start()
        } catch {
            lastInput = String(localized: "Unable to start haptics", bundle: AppResources.localizationBundle)
        }
    }

    private func refreshBattery() {
        guard let battery = controller?.battery else { return }
        batteryLevel = battery.batteryLevel
        batteryState = describeBattery(battery.batteryState)
    }

    private func configureAdaptiveTriggers() {
        guard let gamepad = controller?.extendedGamepad as? GCDualSenseGamepad else { return }
        gamepad.leftTrigger.setModeFeedbackWithStartPosition(0.48, resistiveStrength: 0.18)
        gamepad.rightTrigger.setModeWeaponWithStartPosition(0.62, endPosition: 0.88, resistiveStrength: 0.62)
    }

    private func configurePulseTimer(for state: CodexTaskState) {
        pulseTimer?.invalidate()
        pulseTimer = nil
        guard [.thinking, .needsInput, .listening, .processingVoice].contains(state) else { return }
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pulsePhase += 0.09
                self?.updateLight()
            }
        }
    }

    private func updateLight() {
        guard let light = controller?.light else { return }
        let color = displayedState.color.usingColorSpace(.deviceRGB) ?? .white
        let animation: CGFloat
        switch displayedState {
        case .thinking, .needsInput:
            animation = 0.55 + CGFloat((sin(pulsePhase * 4.4) + 1) * 0.225)
        case .listening:
            animation = 0.72 + CGFloat((sin(pulsePhase * 7.5) + 1) * 0.14)
        case .processingVoice:
            animation = 0.62 + CGFloat((sin(pulsePhase * 8.5) + 1) * 0.19)
        default:
            animation = 0.82
        }
        light.color = GCColor(
            red: Float(color.redComponent * animation),
            green: Float(color.greenComponent * animation),
            blue: Float(color.blueComponent * animation)
        )
    }

    private func transient(at time: TimeInterval, intensity: Float, sharpness: Float) -> CHHapticEvent {
        CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
            ],
            relativeTime: time
        )
    }

    private func continuous(
        at time: TimeInterval,
        duration: TimeInterval,
        intensity: Float,
        sharpness: Float
    ) -> CHHapticEvent {
        CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
            ],
            relativeTime: time,
            duration: duration
        )
    }

    private func describeBattery(_ state: GCDeviceBattery.State?) -> String {
        switch state {
        case .charging: String(localized: "Charging", bundle: AppResources.localizationBundle)
        case .discharging: String(localized: "On battery", bundle: AppResources.localizationBundle)
        case .full: String(localized: "Full", bundle: AppResources.localizationBundle)
        default: String(localized: "Unknown", bundle: AppResources.localizationBundle)
        }
    }
}

private final class BluetoothMicrophoneInputGate: @unchecked Sendable {
    private let lock = NSLock()
    private var suppressed = false
    private var draining = false
    private var lastAudioPacketTime = 0.0
    private var sawControlReportAfterDrain = false

    var isSuppressed: Bool {
        lock.withLock { suppressed }
    }

    var acceptsGameControllerInput: Bool {
        !isSuppressed
    }

    func beginCapture() {
        lock.withLock {
            suppressed = true
            draining = false
            lastAudioPacketTime = ProcessInfo.processInfo.systemUptime
            sawControlReportAfterDrain = false
        }
    }

    func beginDrain() {
        lock.withLock {
            suppressed = true
            draining = true
            lastAudioPacketTime = ProcessInfo.processInfo.systemUptime
            sawControlReportAfterDrain = false
        }
    }

    func noteAudioPacket() {
        lock.withLock {
            lastAudioPacketTime = ProcessInfo.processInfo.systemUptime
        }
    }

    func noteControlReport() {
        lock.withLock {
            if draining {
                sawControlReportAfterDrain = true
            }
        }
    }

    func finishDrainIfQuiet(minimumSilence: TimeInterval) -> Bool {
        lock.withLock {
            guard suppressed, draining, sawControlReportAfterDrain else {
                return false
            }
            let quietFor =
                ProcessInfo.processInfo.systemUptime - lastAudioPacketTime
            guard quietFor >= minimumSilence else { return false }
            suppressed = false
            draining = false
            sawControlReportAfterDrain = false
            return true
        }
    }

    func forceOpen() {
        lock.withLock {
            suppressed = false
            draining = false
            sawControlReportAfterDrain = false
        }
    }
}
