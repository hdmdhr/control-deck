import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

@MainActor
final class AudioDeviceService: ObservableObject {
    @Published private(set) var controllerAudioAvailable = false
    @Published private(set) var controllerAudioName = String(localized: "Not detected", bundle: AppResources.localizationBundle)
    @Published private(set) var codexMicrophoneAvailable = false
    @Published private(set) var codexMicrophoneName =
        DualSenseMicrophoneAggregate.name
    @Published private(set) var lastAudioResult = String(localized: "Not tested", bundle: AppResources.localizationBundle)

    private var codexMicrophoneDevice: AudioObjectID?
    private let microphoneOwnershipToken = UUID()
    private var toneEngine: AVAudioEngine?
    private var tonePlayer: AVAudioPlayerNode?

    init() {
        refresh()
    }

    func refresh() {
        if let device = dualSenseInputDevice() ?? dualSenseOutputDevice() {
            controllerAudioAvailable = true
            controllerAudioName = stringProperty(device, selector: kAudioObjectPropertyName) ?? "DualSense"
        } else {
            controllerAudioAvailable = false
            controllerAudioName = String(localized: "Not detected", bundle: AppResources.localizationBundle)
        }
    }

    @discardableResult
    func ensureCodexMicrophone() -> Bool {
        guard DualSenseMicrophonePublisherCoordinator.acquire(
            for: microphoneOwnershipToken
        ) else {
            codexMicrophoneAvailable = false
            lastAudioResult =
                String(localized: "DualSense Microphone is in use by the other controller app", bundle: AppResources.localizationBundle)
            return false
        }
        guard let sourceDevice = dualSenseInputDevice(),
              let sourceUID = stringProperty(
                  sourceDevice,
                  selector: kAudioDevicePropertyDeviceUID
              )
        else {
            DualSenseMicrophonePublisherCoordinator.release(
                for: microphoneOwnershipToken
            )
            codexMicrophoneAvailable = false
            lastAudioResult = String(localized: "Controller microphone unavailable", bundle: AppResources.localizationBundle)
            return false
        }

        let aggregateResult = DualSenseMicrophoneAggregate.ensureDevice()
        guard aggregateResult.status == noErr,
              aggregateResult.device != kAudioObjectUnknown
        else {
            DualSenseMicrophonePublisherCoordinator.release(
                for: microphoneOwnershipToken
            )
            codexMicrophoneAvailable = false
            lastAudioResult =
                String(localized: "Could not publish \(DualSenseMicrophoneAggregate.name) ", bundle: AppResources.localizationBundle) +
                "(\(aggregateResult.status))"
            return false
        }

        let aggregateDevice = aggregateResult.device
        codexMicrophoneDevice = aggregateDevice
        codexMicrophoneAvailable =
            DualSenseMicrophoneAggregate.attachPhysicalInput(
                sourceUID: sourceUID,
                to: aggregateDevice
            )
        codexMicrophoneName =
            stringProperty(
                aggregateDevice,
                selector: kAudioObjectPropertyName
            ) ?? DualSenseMicrophoneAggregate.name
        lastAudioResult = codexMicrophoneAvailable
            ? String(localized: "\(codexMicrophoneName) is available to Codex", bundle: AppResources.localizationBundle)
            : String(localized: "Could not attach the controller microphone", bundle: AppResources.localizationBundle)
        if !codexMicrophoneAvailable {
            DualSenseMicrophonePublisherCoordinator.release(
                for: microphoneOwnershipToken
            )
        }
        return codexMicrophoneAvailable
    }

    func removeCodexMicrophone() {
        if DualSenseMicrophonePublisherCoordinator.isOwner(
            microphoneOwnershipToken
        ), let existing = codexMicrophoneDevice {
            // Preserve the aggregate identity selected by Codex. Only detach
            // the physical USB source; the Bluetooth publisher can attach its
            // process tap to this same object immediately afterwards.
            _ = DualSenseMicrophoneAggregate.detachPhysicalInput(
                from: existing
            )
        }
        codexMicrophoneDevice = nil
        codexMicrophoneAvailable = false
        DualSenseMicrophonePublisherCoordinator.release(
            for: microphoneOwnershipToken
        )
    }

    /// The physical USB input currently backing the stable controller
    /// microphone. SpeechTranscriber uses this ID directly, so choosing the
    /// controller never changes the Mac's system-default input.
    func speechInputDeviceID() -> AudioObjectID? {
        dualSenseInputDevice()
    }

    @discardableResult
    func playControllerTone(
        frequency: Float = 740,
        duration: TimeInterval = 0.18,
        volume: Float = 0.12
    ) -> Bool {
        guard let device = dualSenseOutputDevice() else {
            lastAudioResult = String(localized: "Controller speaker unavailable", bundle: AppResources.localizationBundle)
            return false
        }

        toneEngine?.stop()
        toneEngine = nil
        tonePlayer = nil

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)

        var selectedDevice = device
        let status = AudioUnitSetProperty(
            engine.outputNode.audioUnit!,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &selectedDevice,
            UInt32(MemoryLayout<AudioObjectID>.size)
        )
        guard status == noErr else {
            lastAudioResult = String(localized: "Speaker selection failed (\(status))", bundle: AppResources.localizationBundle)
            return false
        }

        let hardwareFormat = engine.outputNode.outputFormat(forBus: 0)
        let channels = min(2, hardwareFormat.channelCount)
        guard channels > 0,
              let format = AVAudioFormat(
                  standardFormatWithSampleRate: hardwareFormat.sampleRate,
                  channels: channels
              ),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(hardwareFormat.sampleRate * duration)
              )
        else {
            lastAudioResult = String(localized: "Unsupported controller speaker format", bundle: AppResources.localizationBundle)
            return false
        }

        buffer.frameLength = buffer.frameCapacity
        let frameCount = Int(buffer.frameLength)
        for channel in 0..<Int(channels) {
            guard let samples = buffer.floatChannelData?[channel] else { continue }
            let channelFrequency = frequency * (channel == 0 ? 1 : 1.25)
            for frame in 0..<frameCount {
                let attack = min(1, Float(frame) / 420)
                let release = min(1, Float(frameCount - frame) / 850)
                let phase = Float(frame) * 2 * .pi * channelFrequency / Float(format.sampleRate)
                samples[frame] = sin(phase) * volume * attack * release
            }
        }

        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            player.scheduleBuffer(buffer)
            player.play()
            toneEngine = engine
            tonePlayer = player
            lastAudioResult = String(localized: "Controller speaker played", bundle: AppResources.localizationBundle)
            DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.1) { [weak self] in
                self?.toneEngine?.stop()
                self?.toneEngine = nil
                self?.tonePlayer = nil
            }
            return true
        } catch {
            lastAudioResult = String(localized: "Speaker error: \(error.localizedDescription)", bundle: AppResources.localizationBundle)
            return false
        }
    }

    func runSpeakerSequence(completion: @escaping () -> Void) {
        guard playControllerTone(frequency: 523, duration: 0.22, volume: 0.15) else {
            completion()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in
            _ = self?.playControllerTone(frequency: 784, duration: 0.26, volume: 0.15)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.38, execute: completion)
        }
    }

    private func dualSenseInputDevice() -> AudioObjectID? {
        audioDevices().first {
            isPhysicalDualSense($0) &&
                hasStreams($0, scope: kAudioObjectPropertyScopeInput)
        }
    }

    private func dualSenseOutputDevice() -> AudioObjectID? {
        audioDevices().first {
            isPhysicalDualSense($0) &&
                hasStreams($0, scope: kAudioObjectPropertyScopeOutput)
        }
    }

    private func isPhysicalDualSense(_ device: AudioObjectID) -> Bool {
        let uid = stringProperty(
            device,
            selector: kAudioDevicePropertyDeviceUID
        )
        guard let uid,
              uid != DualSenseMicrophoneAggregate.uid,
              !DualSenseMicrophoneAggregate.legacyUIDs.contains(uid)
        else {
            return false
        }
        let name = stringProperty(
            device,
            selector: kAudioObjectPropertyName
        )
        return name?.localizedCaseInsensitiveContains(
            "DualSense Wireless Controller"
        ) == true
    }

    private func hasStreams(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr &&
            size >= UInt32(MemoryLayout<AudioStreamID>.size)
    }

    private func audioDevices() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr else { return [] }

        var devices = [AudioObjectID](
            repeating: 0,
            count: Int(size) / MemoryLayout<AudioObjectID>.size
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &devices
        ) == noErr else { return [] }
        return devices
    }

    private func stringProperty(
        _ object: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var unmanaged: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &unmanaged) == noErr,
              let value = unmanaged?.takeRetainedValue()
        else { return nil }
        return value as String
    }
}
