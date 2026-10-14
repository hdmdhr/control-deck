import CoreAudio
import Darwin
import Foundation

/// Coordinates the single public controller microphone.
///
/// The in-process token prevents the USB and Bluetooth services from releasing
/// each other's ownership during a transport switch. The advisory file lock
/// prevents overlapping publishers during transport changes or a stale launch.
enum DualSenseMicrophonePublisherCoordinator {
    private static let stateLock = NSLock()
    private static var owner: UUID?
    private static var lockFileDescriptor: Int32 = -1

    static func acquire(for token: UUID) -> Bool {
        stateLock.withLock {
            if owner == token {
                return true
            }
            guard owner == nil else { return false }

            let directory = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0].appendingPathComponent(
                "DualSense Input",
                isDirectory: true
            )
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
            } catch {
                return false
            }
            let path = directory
                .appendingPathComponent("microphone-publisher.lock")
                .path
            let descriptor = Darwin.open(
                path,
                O_CREAT | O_RDWR,
                mode_t(S_IRUSR | S_IWUSR)
            )
            guard descriptor >= 0 else { return false }
            guard Darwin.lockf(descriptor, F_TLOCK, 0) == 0 else {
                Darwin.close(descriptor)
                return false
            }

            lockFileDescriptor = descriptor
            owner = token
            return true
        }
    }

    static func isOwner(_ token: UUID) -> Bool {
        stateLock.withLock { owner == token }
    }

    static func release(for token: UUID) {
        stateLock.withLock {
            guard owner == token else { return }
            if lockFileDescriptor >= 0 {
                _ = Darwin.lockf(lockFileDescriptor, F_ULOCK, 0)
                Darwin.close(lockFileDescriptor)
            }
            lockFileDescriptor = -1
            owner = nil
        }
    }
}

/// The single public Core Audio identity used for both controller transports.
///
/// Keep the aggregate device alive and change only its backing source. Audio
/// clients such as Chromium cache both the device UID and its AudioObjectID, so
/// destroying/recreating the aggregate during a USB/Bluetooth switch makes a
/// previously selected microphone look stale until the client restarts.
enum DualSenseMicrophoneAggregate {
    static let name = "DualSense Microphone"
    static let uid = "com.ianhansel.controldeck.controller-microphone"
    static let legacyUIDs = [
        "com.ianhansel.ps5codex.dualsense-microphone",
        "com.ianhansel.ps5codex.dualsense-microphone.bluetooth"
    ]

    static func ensureDevice() -> (
        device: AudioObjectID,
        status: OSStatus
    ) {
        if let existing = deviceID(forUID: uid) {
            _ = enableTapAutoStart(on: existing)
            removeLegacyDevices()
            return (existing, noErr)
        }

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceIsPrivateKey: false,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(
            description as CFDictionary,
            &device
        )
        guard status == noErr else {
            return (kAudioObjectUnknown, status)
        }
        _ = enableTapAutoStart(on: device)
        removeLegacyDevices()
        return (device, noErr)
    }

    private static func enableTapAutoStart(
        on device: AudioObjectID
    ) -> OSStatus {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyComposition,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var unmanaged: Unmanaged<CFDictionary>?
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        let readStatus = AudioObjectGetPropertyData(
            device,
            &address,
            0,
            nil,
            &size,
            &unmanaged
        )
        guard readStatus == noErr, let unmanaged else {
            return readStatus
        }
        let dictionary = unmanaged.takeRetainedValue() as NSDictionary
        guard var composition = dictionary as? [String: Any] else {
            return kAudioHardwareUnspecifiedError
        }
        composition[kAudioAggregateDeviceTapAutoStartKey] = true
        var value = composition as CFDictionary
        return withUnsafePointer(to: &value) {
            AudioObjectSetPropertyData(
                device,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<CFDictionary>.size),
                $0
            )
        }
    }

    static func attachPhysicalInput(
        sourceUID: String,
        to device: AudioObjectID
    ) -> Bool {
        // A stable aggregate must have only one backing input at a time.
        // Detaching the tap first prevents a transient duplicate-channel
        // device while Core Audio applies the physical subdevice change.
        _ = setTapUIDs([], on: device)
        guard setSubdeviceUIDs([sourceUID], on: device) == noErr else {
            return false
        }
        _ = setMainSubdeviceUID(sourceUID, on: device)
        return waitForInputStreams(device) {
            !objectList(
                device,
                selector: kAudioAggregateDevicePropertyActiveSubDeviceList
            ).isEmpty
        }
    }

    static func detachPhysicalInput(from device: AudioObjectID) -> Bool {
        setSubdeviceUIDs([], on: device) == noErr
    }

    @available(macOS 14.2, *)
    static func attachTap(
        uid tapUID: String,
        to device: AudioObjectID
    ) -> Bool {
        guard detachPhysicalInput(from: device),
              setTapUIDs([tapUID], on: device) == noErr
        else {
            return false
        }
        return waitForInputStreams(device) {
            !objectList(
                device,
                selector: kAudioAggregateDevicePropertySubTapList
            ).isEmpty
        }
    }

    static func detachTap(from device: AudioObjectID) -> Bool {
        setTapUIDs([], on: device) == noErr
    }

    static func hasInputStreams(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(
            device,
            &address,
            0,
            nil,
            &size
        ) == noErr && size >= UInt32(MemoryLayout<AudioStreamID>.size)
    }

    static func hasAttachedTap(_ device: AudioObjectID) -> Bool {
        !objectList(
            device,
            selector: kAudioAggregateDevicePropertySubTapList
        ).isEmpty
    }

    static func deviceID(forUID uid: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidReference = uid as CFString
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &uidReference) { qualifier in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                qualifier,
                &size,
                &deviceID
            )
        }
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            return nil
        }
        return deviceID
    }

    static func stringProperty(
        _ object: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(
            object,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr,
              let value
        else {
            return nil
        }
        // Core Audio's CFString-valued object properties follow the Create
        // rule even though the accessor is named "Get".
        return value.takeRetainedValue() as String
    }

    private static func setSubdeviceUIDs(
        _ uids: [String],
        on device: AudioObjectID
    ) -> OSStatus {
        setStringList(
            uids,
            selector: kAudioAggregateDevicePropertyFullSubDeviceList,
            on: device
        )
    }

    private static func setTapUIDs(
        _ uids: [String],
        on device: AudioObjectID
    ) -> OSStatus {
        setStringList(
            uids,
            selector: kAudioAggregateDevicePropertyTapList,
            on: device
        )
    }

    private static func setStringList(
        _ values: [String],
        selector: AudioObjectPropertySelector,
        on device: AudioObjectID
    ) -> OSStatus {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var list = values as CFArray
        return withUnsafePointer(to: &list) {
            AudioObjectSetPropertyData(
                device,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<CFArray>.size),
                $0
            )
        }
    }

    private static func setMainSubdeviceUID(
        _ uid: String,
        on device: AudioObjectID
    ) -> OSStatus {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyMainSubDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = uid as CFString
        return withUnsafePointer(to: &value) {
            AudioObjectSetPropertyData(
                device,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<CFString>.size),
                $0
            )
        }
    }

    private static func waitForInputStreams(
        _ device: AudioObjectID,
        sourceIsActive: () -> Bool
    ) -> Bool {
        for _ in 0..<50 {
            if hasInputStreams(device), sourceIsActive() {
                return true
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
    }

    private static func objectList(
        _ object: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            object,
            &address,
            0,
            nil,
            &size
        ) == noErr else {
            return []
        }
        var objects = [AudioObjectID](
            repeating: kAudioObjectUnknown,
            count: Int(size) / MemoryLayout<AudioObjectID>.size
        )
        guard AudioObjectGetPropertyData(
            object,
            &address,
            0,
            nil,
            &size,
            &objects
        ) == noErr else {
            return []
        }
        return objects
    }

    private static func removeLegacyDevices() {
        for legacyUID in legacyUIDs where legacyUID != uid {
            guard let legacy = deviceID(forUID: legacyUID) else { continue }
            _ = setTapUIDs([], on: legacy)
            _ = setSubdeviceUIDs([], on: legacy)
            AudioHardwareDestroyAggregateDevice(legacy)
        }
    }
}

/// Publishes this app's otherwise-muted audio output as a real Core Audio input.
///
/// Process taps are the supported macOS mechanism for turning a process output
/// into an aggregate-device input. Unlike a HAL driver, this needs no privileged
/// installation or Core Audio restart.
final class ProcessTapMicrophoneService {
    static let deviceName = DualSenseMicrophoneAggregate.name
    static let deviceUID = DualSenseMicrophoneAggregate.uid
    private static let legacyTapName =
        "DualSense Bluetooth microphone bridge"
    private static var tapName: String {
        let owner =
            Bundle.main.bundleIdentifier ??
            "com.ianhansel.controldeck"
        return "\(legacyTapName) [\(owner)]"
    }

    private(set) var tapID = AudioObjectID(kAudioObjectUnknown)
    private(set) var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private(set) var lastResult = String(localized: "Not published", bundle: AppResources.localizationBundle)
    private let ownershipToken = UUID()

    var isPublished: Bool {
        tapID != kAudioObjectUnknown &&
            aggregateDeviceID != kAudioObjectUnknown
    }

    @discardableResult
    func publish() -> Bool {
        guard #available(macOS 14.2, *) else {
            lastResult = String(localized: "Wireless microphone requires macOS 14.2 or later", bundle: AppResources.localizationBundle)
            return false
        }
        guard DualSenseMicrophonePublisherCoordinator.acquire(
            for: ownershipToken
        ) else {
            lastResult =
                String(localized: "DualSense Microphone is in use by the other controller app", bundle: AppResources.localizationBundle)
            return false
        }
        var published = false
        defer {
            if !published {
                DualSenseMicrophonePublisherCoordinator.release(
                    for: ownershipToken
                )
            }
        }
        // Capture starts must not tear down and rebuild an already-live Core
        // Audio graph. Chromium caches this public device, and unnecessary
        // reattachment can briefly turn its cached input into a dead object.
        if tapID != kAudioObjectUnknown,
           aggregateDeviceID != kAudioObjectUnknown,
           DualSenseMicrophoneAggregate.deviceID(forUID: Self.deviceUID) ==
               aggregateDeviceID,
           DualSenseMicrophoneAggregate.stringProperty(
               tapID,
               selector: kAudioTapPropertyUID
           ) != nil,
           DualSenseMicrophoneAggregate.hasAttachedTap(aggregateDeviceID),
           DualSenseMicrophoneAggregate.hasInputStreams(aggregateDeviceID)
        {
            lastResult = String(localized: "\(Self.deviceName) is available", bundle: AppResources.localizationBundle)
            published = true
            return true
        }
        if tapID != kAudioObjectUnknown,
           let existingTapUID = DualSenseMicrophoneAggregate.stringProperty(
               tapID,
               selector: kAudioTapPropertyUID
           )
        {
            let aggregateResult = DualSenseMicrophoneAggregate.ensureDevice()
            if aggregateResult.status == noErr,
               DualSenseMicrophoneAggregate.attachTap(
                   uid: existingTapUID,
                   to: aggregateResult.device
               )
            {
                aggregateDeviceID = aggregateResult.device
                enableDriftCompensation(on: aggregateResult.device)
                lastResult = String(localized: "\(Self.deviceName) is available", bundle: AppResources.localizationBundle)
                published = true
                return true
            }
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
            aggregateDeviceID = kAudioObjectUnknown
        }

        // Public aggregate devices outlive an abruptly terminated app. Reuse
        // the stable device instead of destroying and recreating it: Chromium
        // and other long-running microphone clients cache the AudioObject and
        // can otherwise retain a dead device ID until they restart.
        let aggregateResult = DualSenseMicrophoneAggregate.ensureDevice()
        guard aggregateResult.status == noErr,
              aggregateResult.device != kAudioObjectUnknown
        else {
            lastResult =
                String(localized: "Could not publish \(Self.deviceName) (\(aggregateResult.status))", bundle: AppResources.localizationBundle)
            return false
        }
        let stableAggregate = aggregateResult.device
        _ = DualSenseMicrophoneAggregate.detachTap(from: stableAggregate)
        _ = DualSenseMicrophoneAggregate.detachPhysicalInput(
            from: stableAggregate
        )
        destroyOrphanedOwnedTaps()

        guard let processID = currentAudioProcessObjectID() else {
            lastResult = String(localized: "Could not find the app's Core Audio process", bundle: AppResources.localizationBundle)
            return false
        }

        let tapDescription = CATapDescription(
            stereoMixdownOfProcesses: [processID]
        )
        tapDescription.name = Self.tapName
        tapDescription.uuid = UUID()
        tapDescription.isPrivate = false
        tapDescription.muteBehavior = .muted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(
            tapDescription,
            &newTapID
        )
        guard tapStatus == noErr, newTapID != kAudioObjectUnknown else {
            lastResult = String(localized: "Could not create wireless audio tap (\(tapStatus))", bundle: AppResources.localizationBundle)
            return false
        }

        guard let tapUID = DualSenseMicrophoneAggregate.stringProperty(
            newTapID,
            selector: kAudioTapPropertyUID
        ) else {
            AudioHardwareDestroyProcessTap(newTapID)
            lastResult = String(localized: "Wireless audio tap has no UID", bundle: AppResources.localizationBundle)
            return false
        }

        guard DualSenseMicrophoneAggregate.attachTap(
            uid: tapUID,
            to: stableAggregate
        ) else {
            _ = DualSenseMicrophoneAggregate.detachTap(from: stableAggregate)
            AudioHardwareDestroyProcessTap(newTapID)
            lastResult = String(localized: "Could not attach wireless audio to \(Self.deviceName)", bundle: AppResources.localizationBundle)
            return false
        }

        enableDriftCompensation(on: stableAggregate)
        tapID = newTapID
        aggregateDeviceID = stableAggregate
        lastResult = String(localized: "\(Self.deviceName) is available", bundle: AppResources.localizationBundle)
        published = true
        return true
    }

    func unpublish() {
        guard #available(macOS 14.2, *) else { return }
        let ownsPublisher =
            DualSenseMicrophonePublisherCoordinator.isOwner(ownershipToken)
        if ownsPublisher,
           aggregateDeviceID != kAudioObjectUnknown {
            // Keep the public aggregate object itself stable for microphone
            // clients that cache device IDs. With no tap attached it exposes
            // no input streams and disappears from normal input pickers.
            _ = DualSenseMicrophoneAggregate.detachTap(
                from: aggregateDeviceID
            )
            _ = DualSenseMicrophoneAggregate.detachPhysicalInput(
                from: aggregateDeviceID
            )
            aggregateDeviceID = kAudioObjectUnknown
        }
        if ownsPublisher, tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        if ownsPublisher {
            destroyOrphanedOwnedTaps()
        }
        DualSenseMicrophonePublisherCoordinator.release(for: ownershipToken)
        lastResult = String(localized: "Wireless microphone is offline", bundle: AppResources.localizationBundle)
    }

    private func currentAudioProcessObjectID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var processIdentifier = getpid()
        var processObjectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &processIdentifier) { qualifier in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                qualifier,
                &size,
                &processObjectID
            )
        }
        guard status == noErr, processObjectID != kAudioObjectUnknown else {
            return nil
        }
        return processObjectID
    }

    @available(macOS 14.2, *)
    private func destroyOrphanedOwnedTaps() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTapList,
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
        ) == noErr else {
            return
        }
        var taps = [AudioObjectID](
            repeating: kAudioObjectUnknown,
            count: Int(size) / MemoryLayout<AudioObjectID>.size
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &taps
        ) == noErr else {
            return
        }
        for tap in taps {
            let name = DualSenseMicrophoneAggregate.stringProperty(
                tap,
                selector: kAudioObjectPropertyName
            )
            // Bundle-qualified names keep cleanup scoped to this app. The
            // legacy unqualified name is removed during this migration.
            if name == Self.tapName || name == Self.legacyTapName {
                AudioHardwareDestroyProcessTap(tap)
            }
        }
    }

    private func enableDriftCompensation(on aggregateDevice: AudioObjectID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertySubTapList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            aggregateDevice,
            &address,
            0,
            nil,
            &size
        ) == noErr else {
            return
        }
        var subTaps = [AudioObjectID](
            repeating: kAudioObjectUnknown,
            count: Int(size) / MemoryLayout<AudioObjectID>.size
        )
        guard AudioObjectGetPropertyData(
            aggregateDevice,
            &address,
            0,
            nil,
            &size,
            &subTaps
        ) == noErr else {
            return
        }
        for subTap in subTaps {
            var driftAddress = AudioObjectPropertyAddress(
                mSelector: kAudioSubTapPropertyDriftCompensation,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var enabled: UInt32 = 1
            AudioObjectSetPropertyData(
                subTap,
                &driftAddress,
                0,
                nil,
                UInt32(MemoryLayout<UInt32>.size),
                &enabled
            )
        }
    }

}
