import CoreGraphics
import Foundation

@MainActor
final class TouchpadGestureEngine {
    var onGesture: ((TouchGesture) -> Void)?
    var onPointerDelta: ((CGFloat, CGFloat) -> Void)?
    var onScrollDelta: ((CGFloat, CGFloat) -> Void)?

    var settings = TouchpadSettings.trackpadDefault

    private struct Contact {
        var active = false
        var point = CGPoint.zero
    }

    private var primary = Contact()
    private var secondary = Contact()
    private var sessionStartedAt: Date?
    private var sessionStartPoint = CGPoint.zero
    private var lastCentroid = CGPoint.zero
    private var lastSessionPoint = CGPoint.zero
    private var maximumFingerCount = 0
    private var maximumMovement: CGFloat = 0
    private var continuousMotionRouted = false
    private var longPressFired = false
    private var sessionID = UUID()

    func update(
        finger: TouchFinger,
        x: Float,
        y: Float,
        active: Bool
    ) {
        let previousFingerCount = fingerCount
        let previousCentroid = centroid
        let point = CGPoint(x: CGFloat(x), y: CGFloat(y))

        switch finger {
        case .primary:
            primary = Contact(active: active, point: point)
        case .secondary:
            secondary = Contact(active: active, point: point)
        }

        let currentFingerCount = fingerCount
        if previousFingerCount == 0, currentFingerCount > 0 {
            beginSession()
        }

        maximumFingerCount = max(maximumFingerCount, currentFingerCount)
        if previousFingerCount > 0, let previousCentroid {
            lastSessionPoint = previousCentroid
        }

        guard currentFingerCount > 0, let currentCentroid = centroid else {
            if previousFingerCount > 0 {
                finishSession()
            }
            return
        }

        if previousFingerCount != currentFingerCount {
            if currentFingerCount > previousFingerCount {
                // Adding a finger moves the centroid even when neither finger
                // moved. Treat that as a new gesture origin, not pointer motion.
                sessionStartPoint = currentCentroid
                lastSessionPoint = currentCentroid
                maximumMovement = 0
            }
            lastCentroid = currentCentroid
            return
        }

        if previousFingerCount > 0 {
            let reference = previousCentroid ?? lastCentroid
            let deltaX = currentCentroid.x - reference.x
            let deltaY = currentCentroid.y - reference.y
            maximumMovement = max(
                maximumMovement,
                hypot(
                    currentCentroid.x - sessionStartPoint.x,
                    currentCentroid.y - sessionStartPoint.y
                )
            )
            routeMotion(
                fingerCount: currentFingerCount,
                deltaX: deltaX,
                deltaY: deltaY
            )
        }
        lastCentroid = currentCentroid
        lastSessionPoint = currentCentroid
    }

    func cancel() {
        primary = Contact()
        secondary = Contact()
        sessionStartedAt = nil
        continuousMotionRouted = false
        sessionID = UUID()
    }

    private var fingerCount: Int {
        (primary.active ? 1 : 0) + (secondary.active ? 1 : 0)
    }

    private var centroid: CGPoint? {
        switch fingerCount {
        case 1:
            return primary.active ? primary.point : secondary.point
        case 2:
            return CGPoint(
                x: (primary.point.x + secondary.point.x) / 2,
                y: (primary.point.y + secondary.point.y) / 2
            )
        default:
            return nil
        }
    }

    private func beginSession() {
        let point = centroid ?? .zero
        sessionStartedAt = Date()
        sessionStartPoint = point
        lastCentroid = point
        lastSessionPoint = point
        maximumFingerCount = max(1, fingerCount)
        maximumMovement = 0
        continuousMotionRouted = false
        longPressFired = false
        sessionID = UUID()
        let expectedID = sessionID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.62) { [weak self] in
            guard let self,
                  self.sessionID == expectedID,
                  self.fingerCount > 0,
                  self.maximumMovement < 0.065
            else { return }
            self.longPressFired = true
            self.onGesture?(
                self.maximumFingerCount >= 2
                    ? .twoFingerLongPress
                    : .oneFingerLongPress
            )
        }
    }

    private func finishSession() {
        guard let startedAt = sessionStartedAt else { return }
        let duration = Date().timeIntervalSince(startedAt)
        let deltaX = Float(lastSessionPoint.x - sessionStartPoint.x)
        let deltaY = Float(lastSessionPoint.y - sessionStartPoint.y)
        let distance = hypot(CGFloat(deltaX), CGFloat(deltaY))

        if !longPressFired {
            if duration <= 0.34, maximumMovement < 0.075 {
                onGesture?(
                    maximumFingerCount >= 2
                        ? .twoFingerTap
                        : .oneFingerTap
                )
            } else if !continuousMotionRouted,
                      duration <= 1.2,
                      distance >= 0.24 {
                onGesture?(
                    TouchGesture.swipe(
                        fingers: maximumFingerCount,
                        deltaX: deltaX,
                        deltaY: deltaY
                    )
                )
            }
        }

        sessionStartedAt = nil
        maximumFingerCount = 0
        maximumMovement = 0
        continuousMotionRouted = false
        longPressFired = false
        sessionID = UUID()
    }

    private func routeMotion(
        fingerCount: Int,
        deltaX: CGFloat,
        deltaY: CGFloat
    ) {
        guard abs(deltaX) < 0.45, abs(deltaY) < 0.45 else { return }
        if fingerCount == 1 {
            switch settings.oneFingerMode {
            case .pointer:
                let scale = 720 * CGFloat(settings.pointerSensitivity)
                onPointerDelta?(deltaX * scale, -deltaY * scale)
                continuousMotionRouted = true
            case .scroll:
                let scale = 540 * CGFloat(settings.scrollSensitivity)
                emitScroll(deltaX: deltaX, deltaY: deltaY, scale: scale)
                continuousMotionRouted = true
            case .gesturesOnly:
                break
            }
        } else if fingerCount >= 2, settings.twoFingerScroll {
            let scale = 820 * CGFloat(settings.scrollSensitivity)
            emitScroll(deltaX: deltaX, deltaY: deltaY, scale: scale)
            continuousMotionRouted = true
        }
    }
    private func emitScroll(deltaX: CGFloat, deltaY: CGFloat, scale: CGFloat) {
        // Controller Y increases upward. Natural scrolling moves the content
        // with the fingers, on both axes, without changing pointer/gesture input.
        let direction: CGFloat = settings.naturalScrolling ? -1 : 1
        onScrollDelta?(-deltaX * scale * direction, deltaY * scale * direction)
    }

}
