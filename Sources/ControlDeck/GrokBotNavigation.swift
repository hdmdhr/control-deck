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

    // A disclosure button is a section header even when macOS exposes AXButton.
    static func isBotButton(role: String, expanded: Bool?, roleDescription: String) -> Bool {
        role == kAXButtonRole && expanded == nil && roleDescription != "sortable"
    }

    private struct Section {
        let button: AXUIElement
        let container: AXUIElement
        let expanded: Bool
    }
    private struct FoldedContext {
        let window: AXUIElement
        let current: String
        let section: AXUIElement
        let order: [String]
    }
    @MainActor private static var foldedContext: FoldedContext?

    private struct Snapshot {
        let names: [String]
        let buttons: [AXUIElement]
        let current: String
        let sections: [Section]
        let sectionByBot: [String: Int]
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
        do {
            if initial.names.contains(initial.current) {
                index = try adjacentIndex(names: initial.names, currentNames: [initial.current], offset: offset)
            } else if let remembered = foldedContext, CFEqual(remembered.window, window) {
                index = try adjacentVisibleIndex(order: remembered.order, visible: initial.names,
                                                 current: initial.current, offset: offset)
            } else { throw SelectionError.unavailable }
        }
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

    /// If the current bot was just folded away, skip hidden rows using the last verified order.
    static func adjacentVisibleIndex(order: [String], visible: [String], current: String, offset: Int) throws -> Int {
        guard offset == -1 || offset == 1, Set(order).count == order.count,
              Set(visible).count == visible.count, let start = order.firstIndex(of: current),
              order.filter({ visible.contains($0) }) == visible else { throw SelectionError.unavailable }
        var index = start + offset
        while order.indices.contains(index) {
            if let target = visible.firstIndex(of: order[index]) { return target }
            index += offset
        }
        throw SelectionError.boundary
    }

    @MainActor
    static func setCurrentSectionExpanded(_ expanded: Bool) async -> (succeeded: Bool, message: String) {
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
        guard let window = element(root, kAXFocusedWindowAttribute), let state = snapshot(window) else {
            return result(false, "Grok Bot current bot is unavailable or ambiguous")
        }
        let section: Section?
        if let index = state.sectionByBot[state.current] {
            section = state.sections[index]
        } else if let remembered = foldedContext, remembered.current == state.current,
                  CFEqual(remembered.window, window) {
            section = state.sections.first { CFEqual($0.button, remembered.section) }
        } else { section = nil }
        guard let section else { return result(false, "Grok Bot current bot has no collapsible section") }
        if section.expanded == expanded { return result(true, "Grok Bot section is already in the requested state") }
        if !expanded {
            foldedContext = FoldedContext(window: window, current: state.current,
                                          section: section.button, order: state.names)
        }
        func focused() -> Bool {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
                  let current = element(root, kAXFocusedWindowAttribute) else { return false }
            return CFEqual(current, window)
        }
        func freshSection() -> Section? {
            guard focused(), let fresh = snapshot(window), fresh.current == state.current else { return nil }
            return fresh.sections.first { CFEqual($0.button, section.button) }
        }
        guard focused() else { return result(false, "Grok Bot focus changed; try again") }
        _ = AXUIElementPerformAction(section.button, kAXPressAction as CFString)
        // Re-read the disclosure state before retrying: never toggle an already changed section.
        for _ in 0..<3 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard let fresh = freshSection() else { return result(false, "Grok Bot section change could not be verified") }
            if fresh.expanded == expanded { return result(true, "Grok Bot section updated") }
        }
        guard let fresh = freshSection(), fresh.expanded != expanded,
              clickVisibleButton(fresh.button, window: window, pid: app.processIdentifier) else {
            return result(false, "Grok Bot section change could not be verified")
        }
        for _ in 0..<3 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard let fresh = freshSection() else { return result(false, "Grok Bot section change could not be verified") }
            if fresh.expanded == expanded { return result(true, "Grok Bot section updated") }
        }
        return result(false, "Grok Bot section change could not be verified")
    }

    @MainActor
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
        guard complete, lists.count == 1 else { return nil }
        var buttons: [AXUIElement] = []
        var sections: [Section] = []
        walk(lists[0], budget: 2_000, complete: &complete) { node in
            let role = string(node, kAXRoleAttribute)
            let expanded = attribute(node, kAXExpandedAttribute) as? Bool
            if let expanded, let parent = element(node, kAXParentAttribute), role == kAXButtonRole {
                sections.append(Section(button: node, container: parent, expanded: expanded))
                return false
            }
            if isBotButton(role: role, expanded: expanded, roleDescription: string(node, kAXRoleDescriptionAttribute)) {
                buttons.append(node)
                return false
            }
            return role != kAXButtonRole
        }
        let names = buttons.map { button -> String in
            // A bot label can append badges; the first text is its name.
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
        guard complete, !names.contains(where: { $0.isEmpty }), Set(names).count == names.count else { return nil }
        var sectionByBot: [String: Int] = [:]
        for (button, name) in zip(buttons, names) {
            var ancestor = element(button, kAXParentAttribute)
            for _ in 0..<80 {
                guard let node = ancestor, !CFEqual(node, lists[0]) else { break }
                let matches = sections.indices.filter { CFEqual(sections[$0].container, node) }
                if matches.count == 1 { sectionByBot[name] = matches[0]; break }
                if matches.count > 1 { return nil }
                ancestor = element(node, kAXParentAttribute)
            }
        }
        let selectedNames = zip(buttons, names).compactMap { button, name in
            (attribute(button, kAXSelectedAttribute) as? Bool) == true ? name : nil
        }
        var knownNames = names
        if let remembered = foldedContext, CFEqual(remembered.window, window),
           sections.contains(where: { CFEqual($0.button, remembered.section) && !$0.expanded }) {
            knownNames.append(remembered.current)
        }
        let matches = Set((headings + selectedNames).filter { knownNames.contains($0) })
        guard matches.count == 1, let current = matches.first else { return nil }
        return Snapshot(names: names, buttons: buttons, current: current,
                        sections: sections, sectionByBot: sectionByBot)
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
