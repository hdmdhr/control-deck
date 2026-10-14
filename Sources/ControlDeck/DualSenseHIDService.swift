import Foundation
import IOKit.hid
import OSLog

final class DualSenseHIDService {
    var onMicrophoneButton: (() -> Void)?
    var onRawButtonChanged: ((ControllerInput, Bool) -> Void)?
    var onBluetoothControlReport: ((Float) -> Void)?
    var onBluetoothMicrophonePacket:
        ((DualSenseBluetoothMicrophonePacket) -> Void)?
    var onBluetoothSpeakerResult: ((String) -> Void)?
    var onTransportChanged: ((ControllerTransport) -> Void)?

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var transport: ControllerTransport = .unknown
    private let reportBufferSize = 1_024
    private let reportBuffer: UnsafeMutablePointer<UInt8>
    private var rawPressedButtons = Set<ControllerInput>()
    private var stateReportSequence: UInt8 = 0
    private var microphoneReportSequence: UInt8 = 0
    private var speakerReportSequence: UInt8 = 0
    private var speakerPacketSequence: UInt8 = 0
    private var receivedAudioPacketCount = 0
    private var speakerRequestGeneration: UInt64 = 0
    private let outputQueue = DispatchQueue(
        label: "com.ianhansel.controldeck.dualsense-output",
        qos: .userInteractive
    )
    private let speakerEncoder = DualSenseBluetoothSpeakerEncoder()
    private var speakerTimer: DispatchSourceTimer?
    private var speakerFrames: [[UInt8]] = []
    private var speakerFrameIndex = 0
    private var microphoneCaptureActive = false
    private var bluetoothAudioInitialized = false
    private let logger = Logger(
        subsystem: "com.ianhansel.controldeck",
        category: "dualsense-hid"
    )

    private(set) var lastBluetoothMicrophoneResult = String(localized: "Not started", bundle: AppResources.localizationBundle)
    private(set) var lastBluetoothSpeakerResult = String(localized: "Not started", bundle: AppResources.localizationBundle)

    init() {
        reportBuffer = .allocate(capacity: reportBufferSize)
        reportBuffer.initialize(repeating: 0, count: reportBufferSize)
    }

    deinit {
        stop()
        reportBuffer.deinitialize(count: reportBufferSize)
        reportBuffer.deallocate()
    }

    func start() {
        guard manager == nil else { return }

        let hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey: 0x054c,
            kIOHIDProductIDKey: 0x0ce6
        ]
        IOHIDManagerSetDeviceMatching(hidManager, matching as CFDictionary)
        IOHIDManagerRegisterDeviceMatchingCallback(
            hidManager,
            { context, _, _, device in
                guard let context else { return }
                let service = Unmanaged<DualSenseHIDService>.fromOpaque(context).takeUnretainedValue()
                service.attach(device)
            },
            Unmanaged.passUnretained(self).toOpaque()
        )
        IOHIDManagerRegisterDeviceRemovalCallback(
            hidManager,
            { context, _, _, device in
                guard let context else { return }
                let service = Unmanaged<DualSenseHIDService>.fromOpaque(context).takeUnretainedValue()
                if service.device === device {
                    service.speakerRequestGeneration &+= 1
                    service.outputQueue.sync {
                        service.cancelBluetoothSpeakerLocked(routeOff: false)
                        service.microphoneCaptureActive = false
                        service.bluetoothAudioInitialized = false
                    }
                    service.device = nil
                    service.transport = .unknown
                    DispatchQueue.main.async {
                        service.onTransportChanged?(.unknown)
                    }
                }
            },
            Unmanaged.passUnretained(self).toOpaque()
        )
        IOHIDManagerScheduleWithRunLoop(hidManager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerOpen(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = hidManager

        if let devices = IOHIDManagerCopyDevices(hidManager) as? Set<IOHIDDevice>,
           let first = devices.first {
            attach(first)
        }
    }

    func stop() {
        guard let manager else { return }
        speakerRequestGeneration &+= 1
        outputQueue.sync {
            cancelBluetoothSpeakerLocked(routeOff: transport == .bluetooth)
        }
        if transport == .bluetooth, device != nil {
            _ = setBluetoothMicrophoneCapture(false)
        }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
        device = nil
        transport = .unknown
        rawPressedButtons.removeAll()
    }

    func setMicrophoneLED(_ state: MicrophoneLEDState) -> Bool {
        guard let device, transport == .usb else { return false }

        // USB output report 0x02. Only the mic LED validity bit is set so the
        // report does not take ownership of lightbar, haptics, or trigger state.
        var report = [UInt8](repeating: 0, count: 63)
        report[0] = 0x02
        report[2] = 0x01
        report[9] = state.rawValue

        let result = report.withUnsafeBytes {
            IOHIDDeviceSetReport(
                device,
                kIOHIDReportTypeOutput,
                0x02,
                $0.bindMemory(to: UInt8.self).baseAddress!,
                report.count
            )
        }
        return result == kIOReturnSuccess
    }

    func setBluetoothMicrophoneCapture(_ active: Bool) -> Bool {
        guard let device, transport == .bluetooth else {
            lastBluetoothMicrophoneResult = String(localized: "DualSense is not connected over Bluetooth", bundle: AppResources.localizationBundle)
            return false
        }

        let results: (state: IOReturn, stream: IOReturn) =
            outputQueue.sync {
                let previousMicrophoneState = microphoneCaptureActive
                microphoneCaptureActive = active
                let stateReport =
                    DualSenseBluetoothAudioProtocol.microphoneStateReport(
                        active: active,
                        muted: !active,
                        sequence: stateReportSequence,
                        speakerActive: speakerTimer != nil
                    )
                stateReportSequence = (stateReportSequence + 1) & 0x0f
                let stateResult = sendOutputReport(
                    stateReport,
                    reportID: 0x31,
                    to: device
                )
                guard stateResult == kIOReturnSuccess else {
                    microphoneCaptureActive = previousMicrophoneState
                    return (stateResult, stateResult)
                }

                let streamReport =
                    DualSenseBluetoothAudioProtocol.microphoneStreamReport(
                        active: active,
                        sequence: microphoneReportSequence
                    )
                microphoneReportSequence =
                    (microphoneReportSequence + 1) & 0x0f
                let streamResult = sendOutputReport(
                    streamReport,
                    reportID: 0x32,
                    to: device
                )
                if streamResult != kIOReturnSuccess {
                    microphoneCaptureActive = previousMicrophoneState
                }
                return (stateResult, streamResult)
            }
        guard results.state == kIOReturnSuccess else {
            lastBluetoothMicrophoneResult =
                String(localized: "Bluetooth microphone state failed (\(ioResult(results.state)))", bundle: AppResources.localizationBundle)
            return false
        }
        guard results.stream == kIOReturnSuccess else {
            lastBluetoothMicrophoneResult =
                String(localized: "Bluetooth microphone command failed (\(ioResult(results.stream)))", bundle: AppResources.localizationBundle)
            logger.error(
                "Bluetooth mic command active=\(active, privacy: .public) failed: \(self.ioResult(results.stream), privacy: .public)"
            )
            return false
        }

        lastBluetoothMicrophoneResult = active
            ? String(localized: "Bluetooth microphone stream opened", bundle: AppResources.localizationBundle)
            : String(localized: "Bluetooth microphone stream closed", bundle: AppResources.localizationBundle)
        logger.notice(
            "Bluetooth mic stream active=\(active, privacy: .public); stateSeq=\(self.stateReportSequence, privacy: .public) streamSeq=\(self.microphoneReportSequence, privacy: .public)"
        )
        return true
    }

    @discardableResult
    func playBluetoothSpeakerTone(
        frequency: Float = 740,
        duration: TimeInterval = 0.18,
        volume: Float = 0.12
    ) -> Bool {
        guard let requestedDevice = device, transport == .bluetooth else {
            lastBluetoothSpeakerResult =
                String(localized: "DualSense is not connected over Bluetooth", bundle: AppResources.localizationBundle)
            return false
        }

        speakerRequestGeneration &+= 1
        let generation = speakerRequestGeneration
        lastBluetoothSpeakerResult = String(localized: "Encoding Bluetooth speaker audio", bundle: AppResources.localizationBundle)
        speakerEncoder.encodeTone(
            frequency: frequency,
            duration: duration,
            volume: volume
        ) { [weak self, requestedDevice] result in
            DispatchQueue.main.async {
                guard let self,
                      generation == self.speakerRequestGeneration,
                      self.device === requestedDevice,
                      self.transport == .bluetooth
                else {
                    return
                }
                switch result {
                case let .success(frames):
                    self.beginBluetoothSpeakerFrames(
                        frames,
                        device: requestedDevice
                    )
                case let .failure(error):
                    let message = error.localizedDescription
                    self.lastBluetoothSpeakerResult = message
                    self.onBluetoothSpeakerResult?(message)
                }
            }
        }
        return true
    }

    private func attach(_ device: IOHIDDevice) {
        guard self.device !== device else { return }
        speakerRequestGeneration &+= 1
        outputQueue.sync {
            cancelBluetoothSpeakerLocked(routeOff: false)
            microphoneCaptureActive = false
            bluetoothAudioInitialized = false
        }
        self.device = device
        let transportName = IOHIDDeviceGetProperty(
            device,
            kIOHIDTransportKey as CFString
        ) as? String
        if transportName?.localizedCaseInsensitiveContains("Bluetooth") == true {
            transport = .bluetooth
        } else if transportName?.localizedCaseInsensitiveContains("USB") == true {
            transport = .usb
        } else {
            transport = .unknown
        }
        rawPressedButtons.removeAll()
        stateReportSequence = 0
        microphoneReportSequence = 0
        speakerReportSequence = 0
        speakerPacketSequence = 0
        receivedAudioPacketCount = 0
        logger.notice(
            "DualSense HID attached over \(self.transport.rawValue, privacy: .public)"
        )
        onTransportChanged?(transport)

        IOHIDDeviceRegisterInputReportCallback(
            device,
            reportBuffer,
            reportBufferSize,
            { context, result, _, _, reportID, report, reportLength in
                guard result == kIOReturnSuccess, let context else { return }
                let service = Unmanaged<DualSenseHIDService>.fromOpaque(context).takeUnretainedValue()
                service.receivedInput(reportID: reportID, report: report, length: reportLength)
            },
            Unmanaged.passUnretained(self).toOpaque()
        )

        // Establish a known, muted microphone state after a previous app
        // crash. Orange means muted on DualSense.
        if transport == .bluetooth {
            let initializationResult = outputQueue.sync {
                let report =
                    DualSenseBluetoothAudioProtocol.audioInitializationReport(
                        microphoneActive: false,
                        speakerActive: false
                    )
                let result = sendOutputReport(
                    report,
                    reportID: 0x32,
                    to: device
                )
                bluetoothAudioInitialized = result == kIOReturnSuccess
                return result
            }
            if initializationResult != kIOReturnSuccess {
                logger.error(
                    "Bluetooth audio initialization failed: \(self.ioResult(initializationResult), privacy: .public)"
                )
            }
            _ = setBluetoothMicrophoneCapture(false)
        } else {
            _ = setMicrophoneLED(.on)
        }
    }

    private func receivedInput(reportID: UInt32, report: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        guard length > 0 else { return }
        let bytes = Array(
            UnsafeBufferPointer(
                start: report,
                count: Int(length)
            )
        )
        if let microphonePacket =
            DualSenseBluetoothAudioProtocol.microphonePacket(
                reportID: reportID,
                bytes: bytes
            ) {
            // Audio reuses report 0x31. It must never fall through to the
            // controller-state parser or random Opus bytes become button input.
            receivedAudioPacketCount += 1
            if receivedAudioPacketCount == 1 {
                logger.notice("Received first Bluetooth microphone packet")
            }
            onBluetoothMicrophonePacket?(microphonePacket)
            return
        }

        let leftTrigger: Float
        let buttons0: UInt8
        let buttons1: UInt8
        let buttons2: UInt8
        switch reportID {
        case 0x01:
            let includesReportID = bytes.count == 64 && bytes[0] == 0x01
            let stateOffset = includesReportID ? 1 : 0
            guard bytes.count >= stateOffset + 10 else { return }
            leftTrigger = Float(bytes[stateOffset + 4]) / 255
            buttons0 = bytes[stateOffset + 7]
            buttons1 = bytes[stateOffset + 8]
            buttons2 = bytes[stateOffset + 9]
        case 0x31:
            guard let frame =
                DualSenseBluetoothAudioProtocol.bluetoothControlFrame(
                    reportID: reportID,
                    bytes: bytes
                )
            else {
                return
            }
            leftTrigger = Float(frame.leftTrigger) / 255
            buttons0 = frame.buttons0
            buttons1 = frame.buttons1
            buttons2 = frame.buttons2
            onBluetoothControlReport?(leftTrigger)
        default:
            return
        }
        let pressedButtons = decodedButtons(
            buttons0: buttons0,
            buttons1: buttons1,
            buttons2: buttons2
        )
        emitRawButtonChanges(pressedButtons)
    }

    private func decodedButtons(
        buttons0: UInt8,
        buttons1: UInt8,
        buttons2: UInt8
    ) -> Set<ControllerInput> {
        var pressed = Set<ControllerInput>()
        let hat = buttons0 & 0x0f
        if [0, 1, 7].contains(hat) { pressed.insert(.dpadUp) }
        if [1, 2, 3].contains(hat) { pressed.insert(.dpadRight) }
        if [3, 4, 5].contains(hat) { pressed.insert(.dpadDown) }
        if [5, 6, 7].contains(hat) { pressed.insert(.dpadLeft) }

        if buttons0 & 0x10 != 0 { pressed.insert(.square) }
        if buttons0 & 0x20 != 0 { pressed.insert(.cross) }
        if buttons0 & 0x40 != 0 { pressed.insert(.circle) }
        if buttons0 & 0x80 != 0 { pressed.insert(.triangle) }

        if buttons1 & 0x01 != 0 { pressed.insert(.l1) }
        if buttons1 & 0x02 != 0 { pressed.insert(.r1) }
        // L2 uses its analog byte so push-to-talk has hysteresis.
        if buttons1 & 0x08 != 0 { pressed.insert(.r2) }
        if buttons1 & 0x10 != 0 { pressed.insert(.create) }
        if buttons1 & 0x20 != 0 { pressed.insert(.options) }
        if buttons1 & 0x40 != 0 { pressed.insert(.l3) }
        if buttons1 & 0x80 != 0 { pressed.insert(.r3) }

        if buttons2 & 0x01 != 0 { pressed.insert(.ps) }
        if buttons2 & 0x02 != 0 { pressed.insert(.touchpadClick) }
        if buttons2 & 0x04 != 0 { pressed.insert(.microphone) }
        return pressed
    }

    private func emitRawButtonChanges(_ pressedButtons: Set<ControllerInput>) {
        let changed = rawPressedButtons.symmetricDifference(pressedButtons)
        let microphoneWasPressed = rawPressedButtons.contains(.microphone)
        rawPressedButtons = pressedButtons
        for input in changed {
            onRawButtonChanged?(input, pressedButtons.contains(input))
        }
        if !microphoneWasPressed, pressedButtons.contains(.microphone) {
            onMicrophoneButton?()
        }
    }

    private func sendOutputReport(
        _ report: [UInt8],
        reportID: CFIndex,
        to device: IOHIDDevice
    ) -> IOReturn {
        report.withUnsafeBytes {
            IOHIDDeviceSetReport(
                device,
                kIOHIDReportTypeOutput,
                reportID,
                $0.bindMemory(to: UInt8.self).baseAddress!,
                report.count
            )
        }
    }

    private func beginBluetoothSpeakerFrames(
        _ frames: [[UInt8]],
        device: IOHIDDevice
    ) {
        guard !frames.isEmpty else {
            lastBluetoothSpeakerResult = String(localized: "Bluetooth speaker audio was empty", bundle: AppResources.localizationBundle)
            onBluetoothSpeakerResult?(lastBluetoothSpeakerResult)
            return
        }
        lastBluetoothSpeakerResult = String(localized: "Streaming to controller speaker", bundle: AppResources.localizationBundle)

        outputQueue.async { [weak self, device] in
            guard let self else { return }
            self.cancelBluetoothSpeakerLocked(routeOff: false)

            if !self.bluetoothAudioInitialized {
                let initialization =
                    DualSenseBluetoothAudioProtocol.audioInitializationReport(
                        microphoneActive: self.microphoneCaptureActive,
                        speakerActive: true
                    )
                let result = self.sendOutputReport(
                    initialization,
                    reportID: 0x32,
                    to: device
                )
                guard result == kIOReturnSuccess else {
                    self.finishBluetoothSpeakerLocked(
                        String(localized: "Bluetooth speaker initialization failed ", bundle: AppResources.localizationBundle) +
                            String(localized: "(\(self.ioResult(result)))", bundle: AppResources.localizationBundle),
                        device: device,
                        restoreRoute: false
                    )
                    return
                }
                self.bluetoothAudioInitialized = true
            }

            let routeReport =
                DualSenseBluetoothAudioProtocol.microphoneStateReport(
                    active: self.microphoneCaptureActive,
                    muted: !self.microphoneCaptureActive,
                    sequence: self.stateReportSequence,
                    speakerActive: true
                )
            self.stateReportSequence = (self.stateReportSequence + 1) & 0x0f
            let routeResult = self.sendOutputReport(
                routeReport,
                reportID: 0x31,
                to: device
            )
            guard routeResult == kIOReturnSuccess else {
                self.finishBluetoothSpeakerLocked(
                    String(localized: "Bluetooth speaker route failed ", bundle: AppResources.localizationBundle) +
                        String(localized: "(\(self.ioResult(routeResult)))", bundle: AppResources.localizationBundle),
                    device: device,
                    restoreRoute: false
                )
                return
            }

            self.speakerFrames = frames
            self.speakerFrameIndex = 0
            let timer = DispatchSource.makeTimerSource(queue: self.outputQueue)
            timer.schedule(
                deadline: .now(),
                repeating: .milliseconds(10),
                leeway: .milliseconds(1)
            )
            timer.setEventHandler { [weak self, device] in
                self?.sendNextBluetoothSpeakerFrame(to: device)
            }
            self.speakerTimer = timer
            timer.resume()
        }
    }

    private func sendNextBluetoothSpeakerFrame(to device: IOHIDDevice) {
        guard speakerFrameIndex < speakerFrames.count else {
            finishBluetoothSpeakerLocked(
                String(localized: "Controller speaker played over Bluetooth", bundle: AppResources.localizationBundle),
                device: device,
                restoreRoute: true
            )
            return
        }

        guard let report =
            DualSenseBluetoothAudioProtocol.speakerAudioReport(
                opusFrame: speakerFrames[speakerFrameIndex],
                reportSequence: speakerReportSequence,
                packetSequence: speakerPacketSequence,
                microphoneActive: microphoneCaptureActive
            )
        else {
            finishBluetoothSpeakerLocked(
                String(localized: "Bluetooth speaker frame had the wrong size", bundle: AppResources.localizationBundle),
                device: device,
                restoreRoute: true
            )
            return
        }
        speakerReportSequence = (speakerReportSequence + 1) & 0x0f
        speakerPacketSequence &+= 1
        let result = sendOutputReport(report, reportID: 0x36, to: device)
        guard result == kIOReturnSuccess else {
            finishBluetoothSpeakerLocked(
                String(localized: "Bluetooth speaker write failed (\(ioResult(result)))", bundle: AppResources.localizationBundle),
                device: device,
                restoreRoute: true
            )
            return
        }
        speakerFrameIndex += 1
    }

    private func finishBluetoothSpeakerLocked(
        _ message: String,
        device: IOHIDDevice,
        restoreRoute: Bool
    ) {
        speakerTimer?.setEventHandler {}
        speakerTimer?.cancel()
        speakerTimer = nil
        speakerFrames.removeAll(keepingCapacity: true)
        speakerFrameIndex = 0

        if restoreRoute {
            let routeReport =
                DualSenseBluetoothAudioProtocol.microphoneStateReport(
                    active: microphoneCaptureActive,
                    muted: !microphoneCaptureActive,
                    sequence: stateReportSequence,
                    speakerActive: false
                )
            stateReportSequence = (stateReportSequence + 1) & 0x0f
            _ = sendOutputReport(routeReport, reportID: 0x31, to: device)
            closeIdleBluetoothMicrophoneLocked(on: device)
        }
        logger.notice(
            "Bluetooth speaker finished: \(message, privacy: .public)"
        )

        DispatchQueue.main.async { [weak self] in
            self?.lastBluetoothSpeakerResult = message
            self?.onBluetoothSpeakerResult?(message)
        }
    }

    private func cancelBluetoothSpeakerLocked(routeOff: Bool) {
        let activeDevice = device
        speakerTimer?.setEventHandler {}
        speakerTimer?.cancel()
        speakerTimer = nil
        speakerFrames.removeAll(keepingCapacity: true)
        speakerFrameIndex = 0
        guard routeOff, let activeDevice else { return }
        let routeReport =
            DualSenseBluetoothAudioProtocol.microphoneStateReport(
                active: microphoneCaptureActive,
                muted: !microphoneCaptureActive,
                sequence: stateReportSequence,
                speakerActive: false
            )
        stateReportSequence = (stateReportSequence + 1) & 0x0f
        _ = sendOutputReport(routeReport, reportID: 0x31, to: activeDevice)
        closeIdleBluetoothMicrophoneLocked(on: activeDevice)
    }

    private func closeIdleBluetoothMicrophoneLocked(on device: IOHIDDevice) {
        guard !microphoneCaptureActive else { return }
        let closeReport =
            DualSenseBluetoothAudioProtocol.microphoneStreamReport(
                active: false,
                sequence: microphoneReportSequence
            )
        microphoneReportSequence = (microphoneReportSequence + 1) & 0x0f
        _ = sendOutputReport(closeReport, reportID: 0x32, to: device)
    }

    private func ioResult(_ result: IOReturn) -> String {
        String(format: "0x%08x", UInt32(bitPattern: result))
    }
}

enum MicrophoneLEDState: UInt8 {
    case off = 0
    case on = 1
    case pulse = 2
}
