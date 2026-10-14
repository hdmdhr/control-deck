import AppKit
import ApplicationServices
import Foundation
import OSLog

/// Conservative reader for the Agents sidebar; accessory buttons are never navigation targets.
enum CursorConversationNavigation {
    struct Node {
        var id: Int
        var role: String
        var label: String = ""
        var roleDescription: String = ""
        var selected = false
        var advertisedAttributes: [String] = []
        var expandedValue: Bool? = nil
        var children: [Node] = []
        var domClasses: [String] = []
        var descendants: [Node] { [self] + children.flatMap(\.descendants) }
        var expanded: Bool? { advertisedAttributes.contains(kAXExpandedAttribute) ? expandedValue : nil }
    }
    struct Workspace {
        let header: Int
        let name: String
        let expanded: Bool
        let disclosure: Int?
    }
    struct Parsed {
        let rows: [Node]
        let anchors: [Node]
        let workspaces: [Workspace]
        let workspaceByRow: [Int: Int]
        let current: String
    }
    enum SelectionError: Error { case unavailable, boundary }

    /// Parse the same small tree representation used by live AX snapshots and regression fixtures.
    static func parse(_ root: Node, rememberedCurrent: String? = nil,
                      diagnose: (String) -> Void = { _ in }) -> Parsed? {
        let candidates = root.descendants.filter { $0.domClasses.contains("ui-sidebar") }
        guard candidates.count == 1, let sidebar = candidates.first else {
            diagnose("semantic sidebar count=\(candidates.count)"); return nil
        }
        let sidebarIDs = Set(sidebar.descendants.map(\.id))
        let activeTabNames = Set(root.descendants.filter { $0.role == kAXTabGroupRole && !sidebarIDs.contains($0.id) }
            .flatMap(\.descendants).filter(\.selected).map(\.label).filter { !$0.isEmpty })
        guard activeTabNames.count == 1, let activeTabName = activeTabNames.first else {
            let groups = root.descendants.filter { $0.role == kAXTabGroupRole && !sidebarIDs.contains($0.id) }
            let roles = groups.flatMap(\.descendants).map(\.role).joined(separator: ",")
            diagnose("tab selection groups=\(groups.count) distinctSelectedNames=\(activeTabNames.count) roles=\(roles)")
            return nil
        }
        var anchors: [Node] = []
        var headers: [Node] = []
        var disclosures: [Node?] = []
        var owners: [Int: Int] = [:]
        var currentWorkspace: Int?
        var acceptsLists = false
        var inWorkspaces = false
        var valid = true
        func listRows(_ list: Node) {
            guard acceptsLists else { return }
            let primary = conversationButtons(in: list)
            for first in primary {
                anchors.append(first)
                if let currentWorkspace { owners[first.id] = currentWorkspace }
            }
        }
        // Chromium can flatten lists out of their workspace container. Consume
        // structural events in document order, retaining the last verified header.
        func visit(_ node: Node) {
            if node.role == kAXButtonRole {
                if node.label == "Workspaces" {
                    inWorkspaces = true; acceptsLists = false; currentWorkspace = nil; return
                }
                if ["Pinned", "Projects"].contains(node.label) {
                    inWorkspaces = false; acceptsLists = true; currentWorkspace = nil; return
                }
                if inWorkspaces && node.roleDescription == "sortable" {
                    let supported = node.descendants.filter { $0.expanded != nil }
                    guard !node.label.isEmpty, supported.count <= 1 else { valid = false; return }
                    currentWorkspace = headers.count
                    headers.append(node)
                    disclosures.append(supported.first)
                    acceptsLists = true
                    return
                }
            }
            if node.role == kAXListRole { listRows(node); return }
            node.children.forEach(visit)
        }
        visit(sidebar)
        let names = anchors.map(\.label)
        guard valid, Set(names).count == names.count else {
            diagnose("invalid rows valid=\(valid) anchors=\(names.count) unique=\(Set(names).count) headers=\(headers.count)")
            return nil
        }
        let workspaces = headers.indices.map { index in
            let regularRowsExist = anchors.contains { owners[$0.id] == index && $0.label != activeTabName }
            return Workspace(header: headers[index].id, name: headers[index].label,
                             expanded: disclosures[index]?.expanded ?? regularRowsExist,
                             disclosure: disclosures[index]?.id)
        }
        let rows = anchors.filter { row in owners[row.id].map { workspaces[$0].expanded } ?? true }
        let known = Set(names + [rememberedCurrent].compactMap { $0 })
        guard known.contains(activeTabName) else {
            let sortableRoles = sidebar.descendants.filter { $0.roleDescription == "sortable" }.map(\.role).joined(separator: ",")
            let listCount = sidebar.descendants.filter { $0.role == kAXListRole }.count
            let triggerCount = sidebar.descendants.filter { $0.domClasses.contains("ui-sidebar-menu-button-trigger") }.count
            diagnose("current tab absent from sidebar anchors=\(anchors.count) headers=\(headers.count) lists=\(listCount) primaryTriggers=\(triggerCount) sortableRoles=\(sortableRoles)")
            return nil
        }
        return Parsed(rows: rows, anchors: anchors, workspaces: workspaces,
                      workspaceByRow: owners, current: activeTabName)
    }
    /// Cursor's SidebarMenuButton places the primary role=button trigger
    /// beneath presentation wrappers, separate from its accessory action group.
    /// Match its source-defined class inside a sidebar list, never arbitrary
    /// buttons elsewhere in the workspace or conversation transcript.
    static func conversationButtons(in list: Node) -> [Node] {
        let excluded = Set(["More", "Archive", "Pin", "Unpin", "New Agent"])
        func eligible(_ node: Node) -> Bool {
            node.role == kAXButtonRole && !node.label.isEmpty && !excluded.contains(node.label)
        }
        let marked = list.descendants.filter {
            $0.role == kAXButtonRole && $0.domClasses.contains("ui-sidebar-menu-button-trigger")
        }
        if !marked.isEmpty { return marked.filter(eligible) }
        // If DOM metadata is unavailable, the observed row signature still
        // identifies a conversation: one title button plus Pin/Unpin/Archive.
        // Require that accessory evidence rather than accepting arbitrary list
        // buttons through wrappers.
        let accessories = Set(["Archive", "Pin", "Unpin"])
        func collect(_ node: Node) -> [Node] {
            guard node.role != kAXButtonRole else { return [] }
            let buttons = node.descendants.filter { $0.role == kAXButtonRole }
            let titles = buttons.filter(eligible)
            if titles.count == 1 && buttons.contains(where: { accessories.contains($0.label) }) {
                return titles
            }
            return node.children.flatMap(collect)
        }
        return collect(list)
    }

    static func adjacentIndex(order: [String], visible: [String], current: String, offset: Int) throws -> Int {
        guard [-1, 1].contains(offset), Set(order).count == order.count,
              Set(visible).count == visible.count, let start = order.firstIndex(of: current),
              order.filter({ visible.contains($0) }) == visible else { throw SelectionError.unavailable }
        var cursor = start + offset
        while order.indices.contains(cursor) {
            if let index = visible.firstIndex(of: order[cursor]) { return index }
            cursor += offset
        }
        throw SelectionError.boundary
    }
    struct SemanticDiscovery<Element> {
        var sidebar: Element?
        var panel: Element?
        var tab: Element?
        var visited = 0
        var depthPruned = 0
        var budgetExhausted = false
    }
    /// Cursor's source gives semantic classes to the sidebar, main panel and
    /// tab viewport. Search breadth first through layout wrappers; never use a
    /// marker's arbitrary ancestor as a boundary for the rest of the window.
    static func semanticRoots<Element>(
        _ root: Element, budget: Int = 3000, maxDepth: Int = 60,
        classes: (Element) -> [String], role: (Element) -> String,
        children: (Element) -> [Element]
    ) -> SemanticDiscovery<Element> {
        var result = SemanticDiscovery<Element>()
        func search(_ start: Element, visit: (Element, [String]) -> Bool) {
            var queue: [(Element, Int)] = [(start, 0)]
            var cursor = 0
            while cursor < queue.count {
                let (node, depth) = queue[cursor]
                cursor += 1
                guard depth <= maxDepth else { result.depthPruned += 1; continue }
                guard result.visited < budget else { result.budgetExhausted = true; return }
                result.visited += 1
                let names = classes(node)
                if visit(node, names) { return }
                guard ![kAXTextAreaRole, kAXTextFieldRole, kAXStaticTextRole].contains(role(node)) else { continue }
                queue.append(contentsOf: children(node).map { ($0, depth + 1) })
            }
        }
        var sidebar: Element?
        var panel: Element?
        search(root) { node, names in
            if sidebar == nil && names.contains("ui-sidebar") { sidebar = node }
            if panel == nil && names.contains("ui-tiling-panel") { panel = node }
            return sidebar != nil && panel != nil
        }
        result.sidebar = sidebar
        result.panel = panel
        guard let panel, !result.budgetExhausted else { return result }
        var exactTab: Element?
        var roleTab: Element?
        search(panel) { node, names in
            if names.contains("ui-tab-system-tabs__viewport") { exactTab = node; return true }
            if roleTab == nil && role(node) == kAXTabGroupRole { roleTab = node }
            return false
        }
        result.tab = exactTab ?? roleTab
        return result
    }

    static func normalizedTabRoot(_ node: Node) -> Node {
        var normalized = node
        normalized.role = kAXTabGroupRole
        return normalized
    }

    private struct Live {
        let parsed: Parsed
        let elements: [Int: AXUIElement]
    }
    private struct Folded {
        let window: AXUIElement
        let current: String
        let header: AXUIElement
        let name: String
        let order: [String]
    }
    @MainActor private static var folded: Folded?
    @MainActor private static var busy = false
    private static let logger = Logger(subsystem: "com.controldeck.app", category: "CursorNavigation")
    private static func diagnose(_ detail: String) {
        // Structural diagnostics contain no conversation names or message content.
        logger.error("Cursor snapshot unavailable: \(detail, privacy: .public)")
    }
    private static func result(_ success: Bool, _ message: String.LocalizationValue) -> (Bool, String) {
        (success, String(localized: message, bundle: AppResources.localizationBundle))
    }
    @MainActor private static func snapshot(_ window: AXUIElement) -> Live? {
        var elements: [Int: AXUIElement] = [:]
        var count = 0
        var complete = true
        func read(_ element: AXUIElement, depth: Int) -> Node {
            count += 1
            let id = count
            guard count <= 5000, depth <= 80 else { complete = false; return Node(id: id, role: "") }
            elements[id] = element
            let role = string(element, kAXRoleAttribute)
            let names = attributeNames(element)
            return Node(id: id, role: role, label: label(element),
                        roleDescription: string(element, kAXRoleDescriptionAttribute),
                        selected: (attribute(element, kAXSelectedAttribute) as? Bool) == true ||
                            (role == kAXRadioButtonRole && (attribute(element, kAXValueAttribute) as? NSNumber)?.intValue == 1),
                        advertisedAttributes: names,
                        expandedValue: names.contains(kAXExpandedAttribute) ? attribute(element, kAXExpandedAttribute) as? Bool : nil,
                        children: (attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).map { read($0, depth: depth + 1) },
                        domClasses: attribute(element, "AXDOMClassList") as? [String] ?? [])
        }
        let roots = semanticRoots(window,
            classes: { attribute($0, "AXDOMClassList") as? [String] ?? [] },
            role: { string($0, kAXRoleAttribute) },
            children: { attribute($0, kAXChildrenAttribute) as? [AXUIElement] ?? [] })
        guard let sidebar = roots.sidebar, let panel = roots.panel, let tab = roots.tab else {
            let sidebarRole = roots.sidebar.map { string($0, kAXRoleAttribute) } ?? "missing"
            let panelRole = roots.panel.map { string($0, kAXRoleAttribute) } ?? "missing"
            diagnose("semantic discovery sidebar=\(roots.sidebar != nil) panel=\(roots.panel != nil) tab=\(roots.tab != nil) sidebarRole=\(sidebarRole) panelRole=\(panelRole) visits=\(roots.visited) depthPruned=\(roots.depthPruned) exhausted=\(roots.budgetExhausted)")
            return nil
        }
        let rawTabTree = read(tab, depth: 0)
        // Normalize only the positively identified viewport or scoped tab group.
        let rawTabRole = rawTabTree.role
        let tabTree = normalizedTabRoot(rawTabTree)
        let sidebarTree = read(sidebar, depth: 0)
        let tree = Node(id: -1, role: kAXWindowRole, children: [sidebarTree, tabTree])
        let selectedCount = tabTree.descendants.filter(\.selected).count
        if !complete {
            diagnose("semantic materialization sidebarRole=\(string(sidebar, kAXRoleAttribute)) panelRole=\(string(panel, kAXRoleAttribute)) tabRole=\(rawTabRole) visits=\(roots.visited) depthPruned=\(roots.depthPruned) selected=\(selectedCount) nodes=\(count)")
        }
        let remembered = folded.flatMap { CFEqual($0.window, window) ? $0 : nil }
        guard complete else { diagnose("materialization limit nodes=\(count)"); return nil }
        guard let parsed = parse(tree, rememberedCurrent: remembered?.current, diagnose: diagnose) else {
            diagnose("semantic parse tabRole=\(rawTabRole) selected=\(selectedCount) visits=\(roots.visited) depthPruned=\(roots.depthPruned)")
            return nil
        }
        if !parsed.anchors.contains(where: { $0.label == parsed.current }) {
            guard let remembered, remembered.current == parsed.current,
                  parsed.workspaces.contains(where: { !$0.expanded && $0.name == remembered.name && elements[$0.header].map { CFEqual($0, remembered.header) } == true }) else { return nil }
        }
        return Live(parsed: parsed, elements: elements)
    }
    @MainActor
    static func navigate(offset: Int) async -> (succeeded: Bool, message: String) {
        await perform(offset: offset, expanded: nil)
    }
    @MainActor
    static func setCurrentWorkspaceExpanded(_ expanded: Bool) async -> (succeeded: Bool, message: String) {
        await perform(offset: nil, expanded: expanded)
    }
    @MainActor private static func perform(offset: Int?, expanded: Bool?) async -> (Bool, String) {
        guard !busy else { return result(false, "Cursor is already switching conversations") }
        busy = true
        defer { busy = false }
        guard AXIsProcessTrusted() else { return result(false, "Accessibility permission is required for controller actions") }
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == "com.todesktop.230313mzl4w4u92" else {
            return result(false, "Bring Cursor to the foreground to navigate conversations")
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = element(root, kAXFocusedWindowAttribute), let initial = snapshot(window) else {
            return result(false, "Cursor current conversation is unavailable or ambiguous")
        }
        func focused() -> Bool {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier &&
                element(root, kAXFocusedWindowAttribute).map { CFEqual($0, window) } == true
        }
        let target: AXUIElement
        let targetName: String
        if let offset {
            let visible = initial.parsed.rows.map(\.label)
            let observedOrder = initial.parsed.anchors.map(\.label)
            let order = observedOrder.contains(initial.parsed.current) ? observedOrder : folded?.order ?? []
            let index: Int
            do { index = try adjacentIndex(order: order, visible: visible, current: initial.parsed.current, offset: offset) }
            catch SelectionError.boundary { return result(false, "Cursor has no adjacent conversation in this direction") }
            catch { return result(false, "Cursor current conversation is unavailable or ambiguous") }
            let row = initial.parsed.rows[index]
            guard let button = initial.elements[row.id] else { return result(false, "Cursor conversation change could not be verified") }
            target = button
            targetName = row.label
        } else {
            let workspace: Workspace?
            if let row = initial.parsed.anchors.first(where: { $0.label == initial.parsed.current }),
               let owner = initial.parsed.workspaceByRow[row.id] { workspace = initial.parsed.workspaces[owner] }
            else if let remembered = folded, CFEqual(remembered.window, window), remembered.current == initial.parsed.current {
                workspace = initial.parsed.workspaces.first { $0.name == remembered.name && initial.elements[$0.header].map { CFEqual($0, remembered.header) } == true }
            } else { workspace = nil }
            guard let workspace, let disclosure = workspace.disclosure, let button = initial.elements[disclosure], let expanded else {
                return result(false, "Cursor current conversation has no collapsible workspace")
            }
            if workspace.expanded == expanded { return result(true, "Cursor workspace is already in the requested state") }
            target = button
            targetName = workspace.name
            if !expanded { folded = Folded(window: window, current: initial.parsed.current, header: initial.elements[workspace.header]!, name: workspace.name, order: initial.parsed.rows.map(\.label)) }
        }
        func check(_ fresh: Live) -> Bool? {
            if offset != nil {
                if fresh.parsed.current == targetName { return true }
                return fresh.parsed.current == initial.parsed.current ? false : nil
            }
            guard fresh.parsed.current == initial.parsed.current,
                  let workspace = fresh.parsed.workspaces.first(where: { $0.name == targetName && ($0.disclosure.flatMap { fresh.elements[$0] }).map { CFEqual($0, target) } == true }) else { return nil }
            return workspace.expanded == expanded
        }
        guard focused() else { return result(false, "Cursor focus changed; try again") }
        let pressResult = AXUIElementPerformAction(target, kAXPressAction as CFString)
        logger.debug("Cursor AXPress result=\(pressResult.rawValue, privacy: .public)")
        for attempt in 0..<2 {
            for _ in 0..<3 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard focused(), let fresh = snapshot(window), let confirmed = check(fresh) else { return result(false, "Cursor conversation change could not be verified") }
                if confirmed { return result(true, offset == nil ? "Cursor workspace updated" : "Cursor switched conversations") }
            }
            if attempt == 0 {
                guard focused(), let fresh = snapshot(window), check(fresh) == false else { return result(false, "Cursor conversation change could not be verified") }
                let button: AXUIElement?
                if offset != nil {
                    guard fresh.parsed.rows.map(\.label) == initial.parsed.rows.map(\.label) else { return result(false, "Cursor conversation change could not be verified") }
                    button = fresh.parsed.rows.first(where: { $0.label == targetName }).flatMap { fresh.elements[$0.id] }
                } else {
                    button = fresh.parsed.workspaces.first(where: { ($0.disclosure.flatMap { fresh.elements[$0] }).map { CFEqual($0, target) } == true }).flatMap { $0.disclosure.flatMap { fresh.elements[$0] } }
                }
                guard let button, clickVisibleButton(button, window: window, pid: app.processIdentifier) else { return result(false, "Cursor conversation change could not be verified") }
            }
        }
        return result(false, "Cursor conversation change could not be verified")
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

    private enum ClickRejection: String {
        case enabledUnavailable, disabled, hidden, minimized, missingFrame
        case outsideWindow, offDisplay, hitTestUnavailable, hitMismatch, focusChanged, eventUnavailable
    }

    @MainActor
    private static func clickVisibleButton(_ button: AXUIElement, window: AXUIElement, pid: pid_t) -> Bool {
        func reject(_ reason: ClickRejection) -> Bool {
            logger.error("Cursor click rejected: \(reason.rawValue, privacy: .public)")
            return false
        }
        guard let enabled = attribute(button, kAXEnabledAttribute) as? Bool else { return reject(.enabledUnavailable) }
        guard enabled else { return reject(.disabled) }
        guard (attribute(button, "AXHidden") as? Bool) != true else { return reject(.hidden) }
        guard (attribute(window, kAXMinimizedAttribute) as? Bool) != true else { return reject(.minimized) }
        guard let frame = rect(button), let windowFrame = rect(window) else { return reject(.missingFrame) }
        guard windowFrame.contains(frame) else { return reject(.outsideWindow) }
        let point = CGPoint(x: frame.midX, y: frame.midY)
        var displayCount: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 0, nil, &displayCount) == .success, displayCount > 0 else { return reject(.offDisplay) }
        // AX hit testing also rejects clipped and covered elements.
        var hit: AXUIElement?
        let system = AXUIElementCreateSystemWide()
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              var node = hit else { return reject(.hitTestUnavailable) }
        var matched = false
        for _ in 0..<20 {
            if CFEqual(node, button) { matched = true; break }
            guard let parent = element(node, kAXParentAttribute) else { break }
            node = parent
        }
        guard matched else { return reject(.hitMismatch) }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let focused = element(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute), CFEqual(focused, window) else {
            return reject(.focusChanged)
        }
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else { return reject(.eventUnavailable) }
        // No mouse-move or cursor warp; deliver only the validated button click.
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        logger.debug("Cursor validated click posted")
        return true
    }

    private static func attributeNames(_ node: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(node, &names) == .success else { return [] }
        return names as? [String] ?? []
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

}
