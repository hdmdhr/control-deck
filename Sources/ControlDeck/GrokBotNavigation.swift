import AppKit
import ApplicationServices
import Foundation

/// Navigates only bot buttons in the foreground Grok Bot window's named sidebar.
enum GrokBotNavigation {
    enum SelectionError: Error { case unavailable, ambiguous, boundary }

    /// Pure selection policy: preserve sidebar order and stop at either end.
    static func adjacentIndex(names: [String], currentNames: [String], offset: Int) throws -> Int {
        guard offset == -1 || offset == 1, !names.isEmpty else { throw SelectionError.unavailable }
        guard Set(names).count == names.count else { throw SelectionError.ambiguous }
        let matches = Set(currentNames.filter { names.contains($0) })
        guard !matches.isEmpty else { throw SelectionError.unavailable }
        guard matches.count == 1, let current = matches.first,
              let index = names.firstIndex(of: current) else { throw SelectionError.ambiguous }
        let target = index + offset
        guard names.indices.contains(target) else { throw SelectionError.boundary }
        return target
    }

    enum Verification: Equatable { case confirmed, unchanged, unexpected }
    static func verification(current: String, initial: String, target: String) -> Verification {
        if current == target { return .confirmed }
        return current == initial ? .unchanged : .unexpected
    }

    @MainActor private static var navigating = false

    private struct Snapshot {
        let names: [String]
        let buttons: [AXUIElement]
        let current: String
    }

    @MainActor
    static func navigate(offset: Int) async -> (succeeded: Bool, message: String) {
        func result(_ success: Bool, _ message: String.LocalizationValue) -> (Bool, String) {
            (success, String(localized: message, bundle: AppResources.localizationBundle))
        }
        guard !navigating else { return result(false, "Grok Bot is already switching bots") }
        navigating = true
        defer { navigating = false }
        guard AXIsProcessTrusted() else { return result(false, "Accessibility permission is required for controller actions") }
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == "com.anysphere.sand" else {
            return result(false, "Bring Grok Bot to the foreground to switch bots")
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = element(root, kAXFocusedWindowAttribute), let initial = snapshot(window) else {
            return result(false, "Grok Bot current bot is unavailable or ambiguous")
        }
        func focused() -> Bool {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
                  let current = element(root, kAXFocusedWindowAttribute) else { return false }
            return CFEqual(current, window)
        }
        let index: Int
        do { index = try adjacentIndex(names: initial.names, currentNames: [initial.current], offset: offset) }
        catch SelectionError.boundary { return result(false, "Grok Bot has no adjacent bot in this direction") }
        catch { return result(false, "Grok Bot current bot is unavailable or ambiguous") }
        let target = initial.names[index]
        guard focused() else { return result(false, "Grok Bot focus changed; try again") }
        _ = AXUIElementPerformAction(initial.buttons[index], kAXPressAction as CFString)
        // AXPress acceptance does not establish that the web UI actually handled it.
        for _ in 0..<3 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard focused(), let state = snapshot(window) else { return result(false, "Grok Bot switch could not be verified") }
            switch verification(current: state.current, initial: initial.current, target: target) {
            case .confirmed: return result(true, "Grok Bot switched bots")
            case .unchanged: break
            case .unexpected: return result(false, "Grok Bot selection changed; try again")
            }
        }
        // Resolve the button again after waiting; stale AX elements must not supply coordinates.
        guard focused(), let state = snapshot(window), state.current == initial.current,
              state.names == initial.names, let targetIndex = state.names.firstIndex(of: target),
              clickVisibleButton(state.buttons[targetIndex], window: window, pid: app.processIdentifier) else {
            return result(false, "Grok Bot could not switch bots")
        }
        for _ in 0..<3 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard focused(), let state = snapshot(window) else { return result(false, "Grok Bot switch could not be verified") }
            switch verification(current: state.current, initial: initial.current, target: target) {
            case .confirmed: return result(true, "Grok Bot switched bots")
            case .unchanged: break
            case .unexpected: return result(false, "Grok Bot selection changed; try again")
            }
        }
        return result(false, "Grok Bot switch could not be verified")
    }

    private static func snapshot(_ window: AXUIElement) -> Snapshot? {
        var lists: [AXUIElement] = []
        var headings: [String] = []
        var complete = true
        walk(window, budget: 4_000, complete: &complete) { node in
            if ["Bot 列表", "Bot list"].contains(label(node)) {
                lists.append(node)
                return false
            }
            if string(node, kAXRoleAttribute) == "AXHeading" { headings.append(label(node)) }
            return true
        }
        guard complete, lists.count == 1 else {
            return nil
        }
        var buttons: [AXUIElement] = []
        walk(lists[0], budget: 2_000, complete: &complete) { node in
            if string(node, kAXRoleAttribute) == kAXButtonRole {
                buttons.append(node)
                return false
            }
            return true
        }
        let names = buttons.map { button -> String in
            // The accessible button label may append a badge (e.g. main bot).
            // The first static text is the bot name, before role/preview text.
            let direct = label(button)
            var name = ""
            walk(button, budget: 100, complete: &complete) { node in
                guard name.isEmpty else { return false }
                if string(node, kAXRoleAttribute) == kAXStaticTextRole {
                    name = label(node)
                    if name.isEmpty { name = string(node, kAXValueAttribute) }
                    return false
                }
                return true
            }
            return name.isEmpty ? direct : name
        }
        guard complete, !names.contains(where: { $0.isEmpty }) else {
            return nil
        }
        let selectedNames = zip(buttons, names).compactMap { button, name in
            (attribute(button, kAXSelectedAttribute) as? Bool) == true ? name : nil
        }
        guard complete, Set(names).count == names.count else { return nil }
        let matches = Set((headings + selectedNames).filter { names.contains($0) })
        guard matches.count == 1, let current = matches.first else { return nil }
        return Snapshot(names: names, buttons: buttons, current: current)
    }

    private static func rect(_ node: AXUIElement) -> CGRect? {
        guard let position = attribute(node, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(node, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
              point.x.isFinite, point.y.isFinite, dimensions.width.isFinite, dimensions.height.isFinite,
              dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    @MainActor
    private static func clickVisibleButton(_ button: AXUIElement, window: AXUIElement, pid: pid_t) -> Bool {
        guard (attribute(button, kAXEnabledAttribute) as? Bool) == true,
              (attribute(button, "AXHidden") as? Bool) != true,
              (attribute(window, kAXMinimizedAttribute) as? Bool) != true,
              let frame = rect(button), let windowFrame = rect(window), windowFrame.contains(frame) else { return false }
        let point = CGPoint(x: frame.midX, y: frame.midY)
        var displayCount: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 0, nil, &displayCount) == .success, displayCount > 0 else { return false }
        // AX hit testing also rejects clipped and covered elements.
        var hit: AXUIElement?
        let system = AXUIElementCreateSystemWide()
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              var node = hit else { return false }
        var matched = false
        for _ in 0..<20 {
            if CFEqual(node, button) { matched = true; break }
            guard let parent = element(node, kAXParentAttribute) else { break }
            node = parent
        }
        guard matched, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let focused = element(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute), CFEqual(focused, window),
              let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else { return false }
        // No mouse-move or cursor warp; deliver only the validated button click.
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private static func attribute(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func string(_ node: AXUIElement, _ name: String) -> String {
        (attribute(node, name) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func label(_ node: AXUIElement) -> String {
        for name in [kAXTitleAttribute, kAXDescriptionAttribute] {
            let value = string(node, name)
            if !value.isEmpty { return value }
        }
        return ""
    }

    private static func element(_ node: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(node, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func walk(_ root: AXUIElement, budget: Int, complete: inout Bool,
                             visit: (AXUIElement) -> Bool) {
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        var visited = 0
        while let (node, depth) = stack.popLast() {
            visited += 1
            guard visited <= budget, depth <= 80 else { complete = false; return }
            guard visit(node) else { continue }
            let children = attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
            stack.append(contentsOf: children.reversed().map { ($0, depth + 1) })
        }
    }
}
