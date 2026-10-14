import AppKit
import ApplicationServices
import OSLog

/// Reads the rendered sidebar rather than Codex's independently sorted task monitor.
enum ChatGPTSidebarNavigation {
    struct Node {
        var id: Int
        var role: String
        var classes: [String] = []
        var label: String = ""
        var current = false
        var expanded: Bool? = nil
        var children: [Node] = []
    }
    struct Row {
        let node: Node
        let occurrence: String
    }
    enum SelectionError: Error { case unavailable, boundary }

    static func adjacentIndex(rows: [Row], remembered: String?, offset: Int) throws -> Int {
        guard [-1, 1].contains(offset), !rows.isEmpty else { throw SelectionError.unavailable }
        let active = rows.indices.filter { rows[$0].node.current }
        // ChatGPT marks every occurrence of the active conversation, including copies
        // in both a project and Recents. Use our last occurrence, otherwise the first.
        guard let first = active.first else { throw SelectionError.unavailable }
        let start = active.first { rows[$0].occurrence == remembered } ?? first
        var target = start + offset
        while rows.indices.contains(target) {
            if !rows[target].node.current { return target }
            target += offset
        }
        throw SelectionError.boundary
    }

    static func rows(in root: Node) -> [Row] {
        var nodes: [Node] = []
        func visit(_ node: Node) {
            if node.expanded == false { return }
            if isConversation(node) { nodes.append(node); return }
            node.children.forEach(visit)
        }
        visit(root)
        if !nodes.contains(where: \.current) {
            let highlighted = nodes.indices.filter { nodes[$0].classes.contains("bg-primary-ghost-hover") }
            // _zo shares this background with an open row menu. Require a single
            // conversation name (duplicate sidebar occurrences are allowed), and
            // reject any row with an expanded accessory/menu before using it.
            let unambiguous = Set(highlighted.map { nodes[$0].label }).count == 1
            if unambiguous && !nodes.contains(where: hasOpenMenu) {
                for index in highlighted { nodes[index].current = true }
            }
        }
        var counts: [String: Int] = [:]
        return nodes.map { node in
            let ordinal = counts[node.label, default: 0]
            counts[node.label] = ordinal + 1
            return Row(node: node, occurrence: "\(node.label)\u{1f}\(ordinal)")
        }
    }

    static func hasOpenMenu(_ node: Node) -> Bool {
        if node.role == kAXMenuRole || node.role == kAXMenuItemRole { return true }
        // This is scoped to a conversation's accessories, never project headings.
        return node.children.contains { $0.expanded == true || hasOpenMenu($0) }
    }

    // Static ChatGPT 26.1007 source: _zo -> ORo emits this class only for
    // conversation/task rows; project headers and pagination use other renderers.
    private static func isConversation(_ node: Node) -> Bool {
        node.role == kAXButtonRole && node.classes.contains("sidebar-item")
            && node.classes.contains("data-[app-action-sidebar-thread-selected=true]:bg-primary-ghost-hover") && !node.label.isEmpty
    }

    /// ChatGPT 26.1007's _zo title uses this exact class only for isActive.
    /// The row's background class is deliberately NOT sufficient: opening its
    /// menu applies that same background to an inactive conversation.
    static func isCurrent(ariaCurrent: String, descendants: [Node]) -> Bool {
        if ariaCurrent == "page" || ariaCurrent == "true" { return true }
        func activeTitle(_ node: Node) -> Bool {
            if isConversation(node) { return false }
            let title = node.classes.contains("text-base") && node.classes.contains("leading-5")
            if title && node.classes.contains("text-[var(--color-text)]") { return true }
            return node.children.contains(where: activeTitle)
        }
        return descendants.contains(where: activeTitle)
    }

    private struct Snapshot {
        let rows: [Row]
        let elements: [Int: AXUIElement]
    }
    @MainActor private static var busy = false
    @MainActor private static var remembered: (window: AXUIElement, occurrence: String)?
    private static let logger = Logger(subsystem: "com.controldeck.app", category: "ChatGPTSidebarNavigation")

    @MainActor
    static func navigate(offset: Int) async -> (succeeded: Bool, message: String) {
        func result(_ ok: Bool, _ message: String.LocalizationValue) -> (Bool, String) {
            let text = String(localized: message, bundle: AppResources.localizationBundle)
            // Only fixed action outcomes; never conversation names or contents.
            logger.notice("Navigation outcome success=\(ok, privacy: .public): \(text, privacy: .public)")
            return (ok, text)
        }
        guard !busy else { return result(false, "ChatGPT is already switching conversations") }
        busy = true
        defer { busy = false }
        guard AXIsProcessTrusted() else { return result(false, "Accessibility permission is required for controller actions") }
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == "com.openai.codex" else {
            return result(false, "Bring ChatGPT to the foreground to navigate its sidebar")
        }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        guard !focusedMenu(application) else {
            return result(false, "Close the ChatGPT menu before switching conversations")
        }
        guard let window = element(application, kAXFocusedWindowAttribute), let initial = snapshot(window) else {
            return result(false, "ChatGPT sidebar conversation is unavailable; open the chat sidebar")
        }
        func focused() -> Bool {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
                && !focusedMenu(application)
                && element(application, kAXFocusedWindowAttribute).map { CFEqual($0, window) } == true
        }
        let index: Int
        do {
            let previous = remembered.flatMap { CFEqual($0.window, window) ? $0.occurrence : nil }
            index = try adjacentIndex(rows: initial.rows, remembered: previous, offset: offset)
        } catch SelectionError.boundary { return result(false, "ChatGPT has no adjacent sidebar conversation") }
        catch {
            let backgroundRows = initial.rows.filter { $0.node.classes.contains("bg-primary-ghost-hover") }.count
            logger.error("Current sidebar row missing, rows=\(initial.rows.count, privacy: .public), backgroundRows=\(backgroundRows, privacy: .public)")
            return result(false, "ChatGPT current sidebar conversation is unavailable")
        }
        let target = initial.rows[index]
        guard focused(), let button = initial.elements[target.node.id] else {
            return result(false, "ChatGPT focus changed; try again")
        }
        let pressResult = AXUIElementPerformAction(button, kAXPressAction as CFString)
        logger.notice("Navigation press result=\(pressResult.rawValue, privacy: .public), rows=\(initial.rows.count, privacy: .public), targetIndex=\(index, privacy: .public)")
        for attempt in 0..<8 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard focused() else {
                logger.notice("Readback aborted: focus/menu changed")
                return result(false, "ChatGPT sidebar switch could not be verified")
            }
            guard let updated = snapshot(window) else {
                logger.notice("Readback aborted: snapshot unavailable")
                return result(false, "ChatGPT sidebar switch could not be verified")
            }
            // Preserve the actual element identity across reordering caused by Recents.
            // Never substitute a same-title conversation from a different project.
            if let selected = updated.rows.first(where: { row in
                row.node.current && updated.elements[row.node.id].map { CFEqual($0, button) } == true
            }) {
                remembered = (window, selected.occurrence)
                return result(true, "ChatGPT switched sidebar conversations")
            }
            if attempt == 3,
               updated.rows.map(\.occurrence) == initial.rows.map(\.occurrence),
               let fresh = updated.rows.first(where: { row in
                   updated.elements[row.node.id].map { CFEqual($0, button) } == true
               }), !fresh.node.current, let freshButton = updated.elements[fresh.node.id] {
                // AXPress may be accepted without invoking the web row handler.
                // Only retry the same still-visible, hit-tested target in the same window.
                let clicked = clickVisibleButton(freshButton, window: window, pid: app.processIdentifier)
                logger.notice("Navigation visible click fallback=\(clicked, privacy: .public)")
            }
            if updated.rows.contains(where: { $0.node.current }) &&
                Set(updated.rows.filter { $0.node.current }.map(\.occurrence)) != Set(initial.rows.filter { $0.node.current }.map(\.occurrence)) {
                logger.notice("Readback selection changed but original target element was replaced")
                return result(false, "ChatGPT sidebar switch could not be verified")
            }
        }
        logger.notice("Readback timed out with unchanged selection")
        return result(false, "ChatGPT sidebar switch could not be verified")
    }

    @MainActor private static func snapshot(_ window: AXUIElement) -> Snapshot? {
        var sidebar: AXUIElement?
        var budget = 1800
        func discover(_ node: AXUIElement, _ depth: Int) {
            guard sidebar == nil, budget > 0, depth < 50 else { return }
            budget -= 1
            if classes(node).contains(where: { $0.hasPrefix("_Navigation_") }) {
                sidebar = node
                return
            }
            // Avoid traversing the message document when the navigation is missing.
            let role = string(node, kAXRoleAttribute)
            if [kAXTextAreaRole, kAXTextFieldRole, kAXStaticTextRole].contains(role) { return }
            for child in children(node) { discover(child, depth + 1) }
        }
        discover(window, 0)
        guard let sidebar else {
            logger.error("Sidebar discovery failed, remaining budget=\(budget, privacy: .public)")
            return nil
        }
        var elements: [Int: AXUIElement] = [:]
        var count = 0
        var complete = true
        func read(_ node: AXUIElement, _ depth: Int) -> Node {
            count += 1
            let id = count
            guard count <= 4000, depth < 70 else { complete = false; return Node(id: id, role: "") }
            elements[id] = node
            let names = attributeNames(node)
            let expanded = names.contains(kAXExpandedAttribute) ? attribute(node, kAXExpandedAttribute) as? Bool : nil
            let current = string(node, "AXARIACurrent")
            let childNodes = expanded == false ? [] : children(node).map { read($0, depth + 1) }
            return Node(id: id, role: string(node, kAXRoleAttribute), classes: classes(node),
                        label: label(node), current: isCurrent(ariaCurrent: current, descendants: childNodes),
                        expanded: expanded, children: childNodes)
        }
        let root = read(sidebar, 0)
        let parsed = rows(in: root)
        guard complete, !parsed.isEmpty else {
            logger.error("Sidebar rows unavailable: complete=\(complete, privacy: .public), nodes=\(count, privacy: .public), rows=\(parsed.count, privacy: .public)")
            return nil
        }
        return Snapshot(rows: parsed, elements: elements)
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

    private static func focusedMenu(_ application: AXUIElement) -> Bool {
        var current = element(application, kAXFocusedUIElementAttribute)
        for _ in 0..<30 {
            guard let node = current else { break }
            if [kAXMenuRole, kAXMenuItemRole].contains(string(node, kAXRoleAttribute)) { return true }
            if CFEqual(node, application) { break }
            current = element(node, kAXParentAttribute)
        }
        return false
    }

    private static func attribute(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success else { return nil }
        return value
    }
    private static func attributeNames(_ node: AXUIElement) -> [String] {
        var value: CFArray?
        guard AXUIElementCopyAttributeNames(node, &value) == .success else { return [] }
        return value as? [String] ?? []
    }
    private static func string(_ node: AXUIElement, _ name: String) -> String {
        (attribute(node, name) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    private static func label(_ node: AXUIElement) -> String {
        let title = string(node, kAXTitleAttribute)
        return title.isEmpty ? string(node, kAXDescriptionAttribute) : title
    }
    private static func classes(_ node: AXUIElement) -> [String] {
        if let value = attribute(node, "AXDOMClassList") as? [String] { return value }
        return string(node, "AXDOMClassList").split(separator: " ").map(String.init)
    }
    private static func children(_ node: AXUIElement) -> [AXUIElement] {
        attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }
    private static func element(_ node: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(node, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
