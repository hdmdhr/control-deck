import Combine
import Foundation

struct ControllerMotionSample: Equatable, Sendable {
    var gravityX: Double
    var gravityY: Double
    var gravityZ: Double
    var accelerationX: Double
    var accelerationY: Double
    var accelerationZ: Double
    var rotationX: Double
    var rotationY: Double
    var rotationZ: Double
    var timestamp: TimeInterval

    static let zero = ControllerMotionSample(
        gravityX: 0,
        gravityY: 0,
        gravityZ: -1,
        accelerationX: 0,
        accelerationY: 0,
        accelerationZ: 0,
        rotationX: 0,
        rotationY: 0,
        rotationZ: 0,
        timestamp: 0
    )
}

/// The unprocessed values supplied by GameController. Some controller and
/// transport combinations (notably a DualSense over Bluetooth) expose total
/// acceleration but do not expose Apple's separated gravity vector.
struct RawControllerMotionSample: Equatable, Sendable {
    var reportedGravityX: Double
    var reportedGravityY: Double
    var reportedGravityZ: Double
    var reportedUserAccelerationX: Double
    var reportedUserAccelerationY: Double
    var reportedUserAccelerationZ: Double
    var totalAccelerationX: Double
    var totalAccelerationY: Double
    var totalAccelerationZ: Double
    var rotationX: Double
    var rotationY: Double
    var rotationZ: Double
    var hasSeparateGravity: Bool
    var timestamp: TimeInterval
}

/// Produces a consistent gravity/user-acceleration sample whether or not the
/// platform separates those signals for us. The fallback is a time-based
/// low-pass filter: deliberate tilts settle into gravity while short impulses
/// remain user acceleration for shake detection.
struct ControllerMotionNormalizer: Sendable {
    private var estimatedGravityX = 0.0
    private var estimatedGravityY = 0.0
    private var estimatedGravityZ = 0.0
    private var lastTimestamp: TimeInterval?
    private var hasEstimate = false

    mutating func reset() {
        self = ControllerMotionNormalizer()
    }

    mutating func normalize(
        _ raw: RawControllerMotionSample
    ) -> ControllerMotionSample {
        let reportedGravityMagnitude = sqrt(
            raw.reportedGravityX * raw.reportedGravityX +
                raw.reportedGravityY * raw.reportedGravityY +
                raw.reportedGravityZ * raw.reportedGravityZ
        )
        let canUseReportedGravity = raw.hasSeparateGravity &&
            reportedGravityMagnitude >= 0.25 &&
            reportedGravityMagnitude <= 1.75

        if canUseReportedGravity {
            estimatedGravityX = raw.reportedGravityX
            estimatedGravityY = raw.reportedGravityY
            estimatedGravityZ = raw.reportedGravityZ
            hasEstimate = true
            lastTimestamp = raw.timestamp
            return ControllerMotionSample(
                gravityX: raw.reportedGravityX,
                gravityY: raw.reportedGravityY,
                gravityZ: raw.reportedGravityZ,
                accelerationX: raw.reportedUserAccelerationX,
                accelerationY: raw.reportedUserAccelerationY,
                accelerationZ: raw.reportedUserAccelerationZ,
                rotationX: raw.rotationX,
                rotationY: raw.rotationY,
                rotationZ: raw.rotationZ,
                timestamp: raw.timestamp
            )
        }

        if !hasEstimate {
            estimatedGravityX = raw.totalAccelerationX
            estimatedGravityY = raw.totalAccelerationY
            estimatedGravityZ = raw.totalAccelerationZ
            hasEstimate = true
        } else {
            let elapsed = raw.timestamp - (lastTimestamp ?? raw.timestamp)
            let delta = min(max(elapsed, 1.0 / 240.0), 0.05)
            let smoothing = 1.0 - exp(-delta / 0.16)
            estimatedGravityX += smoothing *
                (raw.totalAccelerationX - estimatedGravityX)
            estimatedGravityY += smoothing *
                (raw.totalAccelerationY - estimatedGravityY)
            estimatedGravityZ += smoothing *
                (raw.totalAccelerationZ - estimatedGravityZ)
        }
        lastTimestamp = raw.timestamp

        return ControllerMotionSample(
            gravityX: estimatedGravityX,
            gravityY: estimatedGravityY,
            gravityZ: estimatedGravityZ,
            accelerationX: raw.totalAccelerationX - estimatedGravityX,
            accelerationY: raw.totalAccelerationY - estimatedGravityY,
            accelerationZ: raw.totalAccelerationZ - estimatedGravityZ,
            rotationX: raw.rotationX,
            rotationY: raw.rotationY,
            rotationZ: raw.rotationZ,
            timestamp: raw.timestamp
        )
    }
}

@MainActor
final class GyroTelemetry: ObservableObject {
    @Published private(set) var sample = ControllerMotionSample.zero

    func update(_ sample: ControllerMotionSample) {
        self.sample = sample
    }
}

struct TelemetryRateLimiter: Sendable {
    let minimumInterval: TimeInterval
    private(set) var lastPublication = -Double.greatestFiniteMagnitude

    mutating func shouldPublish(at timestamp: TimeInterval) -> Bool {
        guard timestamp - lastPublication >= minimumInterval else {
            return false
        }
        lastPublication = timestamp
        return true
    }
}

struct MotionSampleForwardingGate: Sendable {
    let threshold: Double
    private var lastX: Double?
    private var lastY: Double?

    init(threshold: Double = 0.002) {
        self.threshold = threshold
    }

    mutating func shouldForward(x: Double, y: Double) -> Bool {
        guard let lastX, let lastY else {
            self.lastX = x
            self.lastY = y
            return true
        }
        guard abs(x - lastX) > threshold || abs(y - lastY) > threshold else {
            return false
        }
        self.lastX = x
        self.lastY = y
        return true
    }

    mutating func reset() {
        lastX = nil
        lastY = nil
    }
}

enum GyroGesture: String, Codable, CaseIterable, Identifiable, Sendable {
    case shake
    case tiltLeft
    case tiltRight
    case tiltUp
    case tiltDown
    case twistCounterclockwise
    case twistClockwise

    var id: String { rawValue }

    var label: String {
        switch self {
        case .shake: String(localized: "Hard shake", bundle: AppResources.localizationBundle)
        case .tiltLeft: String(localized: "Hold tilt left", bundle: AppResources.localizationBundle)
        case .tiltRight: String(localized: "Hold tilt right", bundle: AppResources.localizationBundle)
        case .tiltUp: String(localized: "Hold tilt up", bundle: AppResources.localizationBundle)
        case .tiltDown: String(localized: "Hold tilt down", bundle: AppResources.localizationBundle)
        case .twistCounterclockwise: String(localized: "Twist counter-clockwise", bundle: AppResources.localizationBundle)
        case .twistClockwise: String(localized: "Twist clockwise", bundle: AppResources.localizationBundle)
        }
    }

    var systemImage: String {
        switch self {
        case .shake: "waveform.path"
        case .tiltLeft: "arrow.left"
        case .tiltRight: "arrow.right"
        case .tiltUp: "arrow.up"
        case .tiltDown: "arrow.down"
        case .twistCounterclockwise: "rotate.left"
        case .twistClockwise: "rotate.right"
        }
    }

    var suggestedAction: MappedAction {
        switch self {
        case .shake: .deleteTextWithConfirmation
        case .tiltLeft: .back
        case .tiltRight: .forward
        case .tiltUp: .missionControl
        case .tiltDown: .showDesktop
        case .twistCounterclockwise: .browserPreviousTab
        case .twistClockwise: .browserNextTab
        }
    }
}

struct GyroSettings: Codable, Equatable, Sendable {
    var enabled: Bool
    var shakeThreshold: Double
    var tiltThreshold: Double
    var rotationThreshold: Double
    var gestureBindings: [String: String]

    func action(for gesture: GyroGesture) -> MappedAction {
        guard let rawValue = gestureBindings[gesture.rawValue] else {
            return .none
        }
        return MappedAction(rawValue: rawValue) ?? .none
    }

    mutating func setAction(_ action: MappedAction, for gesture: GyroGesture) {
        gestureBindings[gesture.rawValue] = action.rawValue
    }

    static let shakeOnly = GyroSettings(
        enabled: true,
        shakeThreshold: 2.25,
        tiltThreshold: 0.68,
        rotationThreshold: 3.4,
        gestureBindings: [
            GyroGesture.shake.rawValue:
                MappedAction.deleteTextWithConfirmation.rawValue
        ]
    )

    static let suggested = GyroSettings(
        enabled: true,
        shakeThreshold: 2.25,
        tiltThreshold: 0.68,
        rotationThreshold: 3.4,
        gestureBindings: Dictionary(
            uniqueKeysWithValues: GyroGesture.allCases.map {
                ($0.rawValue, $0.suggestedAction.rawValue)
            }
        )
    )
}

struct GyroGestureEngine: Sendable {
    private var shakeArmed = true
    private var shakePeakCount = 0
    private var lastShakeSign = 0.0
    private var lastShakePeakTime = 0.0
    private var candidate: GyroGesture?
    private var candidateStartedAt = 0.0
    private var lastGestureTime = -Double.greatestFiniteMagnitude

    mutating func reset() {
        self = GyroGestureEngine()
    }

    mutating func update(
        _ sample: ControllerMotionSample,
        settings: GyroSettings
    ) -> GyroGesture? {
        guard settings.enabled else {
            reset()
            return nil
        }

        if let shake = detectShake(sample, threshold: settings.shakeThreshold) {
            return shake
        }
        guard sample.timestamp - lastGestureTime >= 0.9 else { return nil }

        let nextCandidate: GyroGesture?
        if sample.gravityX <= -settings.tiltThreshold {
            nextCandidate = .tiltLeft
        } else if sample.gravityX >= settings.tiltThreshold {
            nextCandidate = .tiltRight
        } else if sample.gravityY >= settings.tiltThreshold {
            nextCandidate = .tiltUp
        } else if sample.gravityY <= -settings.tiltThreshold {
            nextCandidate = .tiltDown
        } else if sample.rotationZ <= -settings.rotationThreshold {
            nextCandidate = .twistCounterclockwise
        } else if sample.rotationZ >= settings.rotationThreshold {
            nextCandidate = .twistClockwise
        } else {
            candidate = nil
            return nil
        }

        if candidate != nextCandidate {
            candidate = nextCandidate
            candidateStartedAt = sample.timestamp
            return nil
        }
        guard sample.timestamp - candidateStartedAt >= 0.32,
              let gesture = candidate
        else { return nil }
        candidate = nil
        lastGestureTime = sample.timestamp
        return gesture
    }

    private mutating func detectShake(
        _ sample: ControllerMotionSample,
        threshold: Double
    ) -> GyroGesture? {
        let components = [
            sample.accelerationX,
            sample.accelerationY,
            sample.accelerationZ
        ]
        let magnitude = sqrt(components.reduce(0) { $0 + $1 * $1 })
        if magnitude <= threshold * 0.46 {
            shakeArmed = true
            return nil
        }
        guard shakeArmed, magnitude >= threshold else { return nil }
        shakeArmed = false

        let dominant = components.max { abs($0) < abs($1) } ?? 0
        let sign = dominant >= 0 ? 1.0 : -1.0
        let closeEnough = sample.timestamp - lastShakePeakTime <= 0.72
        if closeEnough, sign != lastShakeSign {
            shakePeakCount += 1
        } else {
            shakePeakCount = 1
        }
        lastShakeSign = sign
        lastShakePeakTime = sample.timestamp

        guard shakePeakCount >= 3,
              sample.timestamp - lastGestureTime >= 1.8
        else { return nil }
        shakePeakCount = 0
        lastGestureTime = sample.timestamp
        candidate = nil
        return .shake
    }
}
