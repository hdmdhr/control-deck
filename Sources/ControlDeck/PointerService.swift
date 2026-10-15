import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

@MainActor
final class PointerService: ObservableObject {
    @Published private(set) var lastMovementSource = "Off"
    @Published private(set) var isSelectingScreenshot = false
    var onScreenshotCaptured: ((NSImage) -> Void)?
    var onScreenshotCaptureFailed: ((String) -> Void)?
    var keepScreenshotOnClipboard = true

    private var timer: Timer?
    private var vector = CGPoint.zero
    private var vectorSource: ControllerStick = .off
    private var settings = StickPointerSettings.generalDefault
    private var lastTick = Date()
    private var scrollTimer: Timer?
    private var scrollVector = CGPoint.zero
    private var scrollVectorSource: ControllerStick = .off
    private var scrollSettings = StickPointerSettings.generalDefault
    private var lastScrollTick = Date()
    private var caretTimer: Timer?
    private var caretEngine = CaretStickEngine()
    private var caretSource: ControllerStick = .off
    private var caretApplicationPID: pid_t?
    /// Rechecked by the repeat timer even if no further controller report arrives.
    var caretInputAllowed: () -> Bool = { true }
    var onCaretStep: (CaretStickEngine.Direction) -> Void = PointerService.postCaretStep
    private var screenshotGeneration = 0
    private var screenshotDragStarted = false
    private var screenshotPasteboardChangeCount = 0
    private var priorPasteboardItems: [NSPasteboardItem] = []
    private var leftButtonHeld = false
    private var rightButtonHeld = false
    private var middleButtonHeld = false

    func updateStick(
        _ stick: ControllerStick,
        x: Float,
        y: Float,
        settings: StickPointerSettings
    ) {
        self.settings = settings
        // Explicit caret assignments take precedence over pointer and scrolling.
        let effectiveSource = settings.source == settings.caretSource
            ? ControllerStick.off : settings.source
        if vectorSource != effectiveSource {
            vector = .zero
            vectorSource = effectiveSource
        }
        guard effectiveSource != .off, effectiveSource == stick else {
            if effectiveSource == .off {
                vector = .zero
                lastMovementSource = "Off"
            }
            return
        }
        vector = CGPoint(x: CGFloat(x), y: CGFloat(y))
        vectorSource = stick
        lastMovementSource = stick.label
        ensureTimer()
    }

    func updateScrollStick(
        _ stick: ControllerStick,
        x: Float,
        y: Float,
        settings: StickPointerSettings,
        pointerSource: ControllerStick
    ) {
        scrollSettings = settings
        let effectiveSource = settings.scrollSource == pointerSource ||
            settings.scrollSource == settings.caretSource
            ? ControllerStick.off
            : settings.scrollSource
        if scrollVectorSource != effectiveSource {
            scrollVector = .zero
            scrollVectorSource = effectiveSource
        }
        guard effectiveSource != .off, effectiveSource == stick else {
            if effectiveSource == .off {
                scrollVector = .zero
                scrollTimer?.invalidate()
                scrollTimer = nil
            }
            return
        }
        scrollVector = CGPoint(x: CGFloat(x), y: CGFloat(y))
        scrollVectorSource = stick
        ensureScrollTimer()
    }

    func updateCaretStick(
        _ stick: ControllerStick,
        x: Float,
        y: Float,
        settings: StickPointerSettings
    ) {
        if caretSource != settings.caretSource {
            stopCaret()
            caretSource = settings.caretSource
        }
        guard caretSource != .off, caretSource == stick else { return }
        guard caretInputAllowed(), !isSelectingScreenshot else {
            stopCaret()
            return
        }
        let applicationPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if caretApplicationPID != applicationPID {
            stopCaret()
            caretApplicationPID = applicationPID
        }
        if let direction = caretEngine.update(
            x: x, y: y, now: ProcessInfo.processInfo.systemUptime
        ) {
            onCaretStep(direction)
        }
        if caretEngine.hasPendingRepeat {
            ensureCaretTimer()
        } else {
            caretTimer?.invalidate()
            caretTimer = nil
        }
    }

    /// Context recovery may observe a real centered hardware sample even when
    /// the controller emits no value-changed event. This path never emits keys.
    func observeCaretNeutral(x: Float, y: Float, settings: StickPointerSettings) {
        guard x.isFinite, y.isFinite,
              max(abs(x), abs(y)) <= CaretStickEngine.releaseThreshold else { return }
        updateCaretStick(settings.caretSource, x: x, y: y, settings: settings)
    }

    /// A fresh neutral sample is required after every takeover or context change.
    func stopCaret() {
        caretEngine.reset()
        caretTimer?.invalidate()
        caretTimer = nil
    }

    func stop() {
        stopCaret()
        vector = .zero
        vectorSource = .off
        timer?.invalidate()
        timer = nil
        scrollVector = .zero
        scrollVectorSource = .off
        scrollTimer?.invalidate()
        scrollTimer = nil
        releaseAllButtons()
    }

    func moveImmediately(deltaX: CGFloat, deltaY: CGFloat) {
        guard abs(deltaX) > 0.01 || abs(deltaY) > 0.01 else { return }
        postPointerMove(deltaX: deltaX, deltaY: deltaY)
    }

    func click(_ button: CGMouseButton) {
        setButton(button, pressed: true)
        setButton(button, pressed: false)
    }

    func setButton(_ button: CGMouseButton, pressed: Bool) {
        guard isButtonHeld(button) != pressed,
              let current = CGEvent(source: nil)?.location
        else {
            return
        }
        let eventType: CGEventType
        switch button {
        case .left:
            eventType = pressed ? .leftMouseDown : .leftMouseUp
            leftButtonHeld = pressed
        case .right:
            eventType = pressed ? .rightMouseDown : .rightMouseUp
            rightButtonHeld = pressed
        default:
            eventType = pressed ? .otherMouseDown : .otherMouseUp
            middleButtonHeld = pressed
        }
        CGEvent(
            mouseEventSource: nil,
            mouseType: eventType,
            mouseCursorPosition: current,
            mouseButton: button
        )?.post(tap: .cghidEventTap)
    }

    @discardableResult
    func beginScreenshotSelection() -> Bool {
        guard !isSelectingScreenshot else { return true }
        guard AXIsProcessTrusted() else { return false }
        guard let down = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(kVK_ANSI_4),
            keyDown: true
        ), let up = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(kVK_ANSI_4),
            keyDown: false
        ) else {
            return false
        }

        stopCaret()
        screenshotGeneration += 1
        let generation = screenshotGeneration
        isSelectingScreenshot = true
        screenshotDragStarted = false
        let pasteboard = NSPasteboard.general
        screenshotPasteboardChangeCount = pasteboard.changeCount
        priorPasteboardItems = snapshotPasteboard(pasteboard)
        down.flags = [.maskCommand, .maskShift, .maskControl]
        up.flags = [.maskCommand, .maskShift, .maskControl]
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
            [weak self] in
            guard let self,
                  self.isSelectingScreenshot,
                  self.screenshotGeneration == generation,
                  let current = CGEvent(source: nil)?.location
            else {
                return
            }
            CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDown,
                mouseCursorPosition: current,
                mouseButton: .left
            )?.post(tap: .cghidEventTap)
            self.screenshotDragStarted = true
        }
        return true
    }

    func endScreenshotSelection() {
        guard isSelectingScreenshot else { return }
        screenshotGeneration += 1
        let generation = screenshotGeneration
        if screenshotDragStarted,
           let current = CGEvent(source: nil)?.location {
            CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseUp,
                mouseCursorPosition: current,
                mouseButton: .left
            )?.post(tap: .cghidEventTap)
            awaitScreenshot(generation: generation, remainingAttempts: 50)
        } else {
            postEscape()
        }
        screenshotDragStarted = false
        isSelectingScreenshot = false
    }

    private func awaitScreenshot(
        generation: Int,
        remainingAttempts: Int
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            [weak self] in
            guard let self, self.screenshotGeneration == generation else {
                return
            }
            let pasteboard = NSPasteboard.general
            if pasteboard.changeCount != self.screenshotPasteboardChangeCount,
               let image = pasteboard.readObjects(
                   forClasses: [NSImage.self],
                   options: nil
               )?.first as? NSImage {
                if !self.keepScreenshotOnClipboard {
                    self.restorePasteboard(
                        pasteboard,
                        items: self.priorPasteboardItems
                    )
                }
                self.priorPasteboardItems.removeAll()
                self.onScreenshotCaptured?(image)
                return
            }
            guard remainingAttempts > 1 else {
                self.priorPasteboardItems.removeAll()
                self.onScreenshotCaptureFailed?(
                    String(localized: "The screen capture did not reach the clipboard", bundle: AppResources.localizationBundle)
                )
                return
            }
            self.awaitScreenshot(
                generation: generation,
                remainingAttempts: remainingAttempts - 1
            )
        }
    }

    private func snapshotPasteboard(
        _ pasteboard: NSPasteboard
    ) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { source in
            let copy = NSPasteboardItem()
            for type in source.types {
                if let data = source.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private func restorePasteboard(
        _ pasteboard: NSPasteboard,
        items: [NSPasteboardItem]
    ) {
        pasteboard.clearContents()
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }

    func scroll(deltaX: CGFloat, deltaY: CGFloat) {
        let vertical = Int32(deltaY.rounded())
        let horizontal = Int32(deltaX.rounded())
        guard vertical != 0 || horizontal != 0 else { return }
        CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: vertical,
            wheel2: horizontal,
            wheel3: 0
        )?.post(tap: .cghidEventTap)
    }

    private func ensureCaretTimer() {
        guard caretTimer == nil else { return }
        let repeatTimer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.caretInputAllowed(),
                      !self.isSelectingScreenshot,
                      self.caretApplicationPID == NSWorkspace.shared.frontmostApplication?.processIdentifier
                else {
                    self.stopCaret()
                    return
                }
                if let direction = self.caretEngine.tick(now: ProcessInfo.processInfo.systemUptime) {
                    self.onCaretStep(direction)
                }
                if !self.caretEngine.hasPendingRepeat {
                    self.caretTimer?.invalidate()
                    self.caretTimer = nil
                }
            }
        }
        ContinuousInputRunLoop.add(repeatTimer)
        caretTimer = repeatTimer
    }

    private static func postCaretStep(_ direction: CaretStickEngine.Direction) {
        let key: Int
        switch direction {
        case .left: key = kVK_LeftArrow
        case .right: key = kVK_RightArrow
        case .up: key = kVK_UpArrow
        case .down: key = kVK_DownArrow
        }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: false)
        else { return }
        down.flags = []
        up.flags = []
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func ensureTimer() {
        guard timer == nil else { return }
        lastTick = Date()
        let movementTimer = Timer(
            timeInterval: 1.0 / 60.0,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        ContinuousInputRunLoop.add(movementTimer)
        timer = movementTimer
    }

    private func ensureScrollTimer() {
        guard scrollTimer == nil else { return }
        lastScrollTick = Date()
        let movementTimer = Timer(
            timeInterval: 1.0 / 60.0,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scrollTick()
            }
        }
        ContinuousInputRunLoop.add(movementTimer)
        scrollTimer = movementTimer
    }

    private func tick() {
        let now = Date()
        let elapsed = min(0.05, now.timeIntervalSince(lastTick))
        lastTick = now

        let deadZone = CGFloat(settings.deadZone)
        let magnitude = hypot(vector.x, vector.y)
        guard magnitude > deadZone else {
            if magnitude < 0.01 {
                timer?.invalidate()
                timer = nil
            }
            return
        }

        let normalized = min(1, (magnitude - deadZone) / (1 - deadZone))
        let accelerated = pow(normalized, CGFloat(settings.acceleration))
        let distance = CGFloat(settings.speed) * CGFloat(elapsed) * accelerated
        let direction = CGPoint(x: vector.x / magnitude, y: vector.y / magnitude)
        postPointerMove(
            deltaX: direction.x * distance,
            deltaY: -direction.y * distance
        )
    }

    private func scrollTick() {
        let now = Date()
        let elapsed = min(0.05, now.timeIntervalSince(lastScrollTick))
        lastScrollTick = now

        let deadZone = CGFloat(scrollSettings.scrollDeadZone)
        let magnitude = hypot(scrollVector.x, scrollVector.y)
        guard magnitude > deadZone else {
            if magnitude < 0.01 {
                scrollTimer?.invalidate()
                scrollTimer = nil
            }
            return
        }

        let normalized = min(
            1,
            (magnitude - deadZone) / (1 - deadZone)
        )
        let accelerated = pow(
            normalized,
            CGFloat(scrollSettings.scrollAcceleration)
        )
        let distance =
            CGFloat(scrollSettings.scrollSpeed) *
            CGFloat(elapsed) *
            accelerated
        let direction = CGPoint(
            x: scrollVector.x / magnitude,
            y: scrollVector.y / magnitude
        )
        scroll(
            deltaX: -direction.x * distance,
            deltaY: direction.y * distance
        )
    }

    private func postPointerMove(deltaX: CGFloat, deltaY: CGFloat) {
        guard let current = CGEvent(source: nil)?.location else { return }
        let proposed = CGPoint(
            x: current.x + deltaX,
            y: current.y + deltaY
        )
        let next = DisplayGeometry.constrainedPoint(
            proposed,
            displays: activeDisplayBounds()
        )
        let eventType: CGEventType
        let button: CGMouseButton
        if screenshotDragStarted || leftButtonHeld {
            eventType = .leftMouseDragged
            button = .left
        } else if rightButtonHeld {
            eventType = .rightMouseDragged
            button = .right
        } else if middleButtonHeld {
            eventType = .otherMouseDragged
            button = .center
        } else {
            eventType = .mouseMoved
            button = .left
        }
        CGEvent(
            mouseEventSource: nil,
            mouseType: eventType,
            mouseCursorPosition: next,
            mouseButton: button
        )?.post(tap: .cghidEventTap)
    }

    private func activeDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success,
              count > 0
        else {
            return [CGDisplayBounds(CGMainDisplayID())]
        }
        var displays = [CGDirectDisplayID](
            repeating: 0,
            count: Int(count)
        )
        guard CGGetActiveDisplayList(
            count,
            &displays,
            &count
        ) == .success else {
            return [CGDisplayBounds(CGMainDisplayID())]
        }
        return displays.prefix(Int(count)).map(CGDisplayBounds)
    }

    private func isButtonHeld(_ button: CGMouseButton) -> Bool {
        switch button {
        case .left: leftButtonHeld
        case .right: rightButtonHeld
        default: middleButtonHeld
        }
    }

    private func releaseAllButtons() {
        if leftButtonHeld {
            setButton(.left, pressed: false)
        }
        if rightButtonHeld {
            setButton(.right, pressed: false)
        }
        if middleButtonHeld {
            setButton(.center, pressed: false)
        }
    }

    private func postEscape() {
        guard let down = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(kVK_Escape),
            keyDown: true
        ), let up = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(kVK_Escape),
            keyDown: false
        ) else {
            return
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

enum ContinuousInputRunLoop {
    static let modes: [RunLoop.Mode] = [
        .common,
        .eventTracking,
        .modalPanel
    ]

    @MainActor
    static func add(_ timer: Timer) {
        for mode in modes {
            RunLoop.main.add(timer, forMode: mode)
        }
    }
}

enum DisplayGeometry {
    static func constrainedPoint(
        _ proposed: CGPoint,
        displays: [CGRect]
    ) -> CGPoint {
        guard !displays.isEmpty else { return proposed }
        if displays.contains(where: { $0.contains(proposed) }) {
            return proposed
        }
        return displays
            .map { bounds in
                CGPoint(
                    x: min(
                        max(bounds.minX, proposed.x),
                        bounds.maxX - 1
                    ),
                    y: min(
                        max(bounds.minY, proposed.y),
                        bounds.maxY - 1
                    )
                )
            }
            .min {
                squaredDistance($0, proposed) <
                    squaredDistance($1, proposed)
            } ?? proposed
    }

    private static func squaredDistance(
        _ lhs: CGPoint,
        _ rhs: CGPoint
    ) -> CGFloat {
        let x = lhs.x - rhs.x
        let y = lhs.y - rhs.y
        return x * x + y * y
    }
}
