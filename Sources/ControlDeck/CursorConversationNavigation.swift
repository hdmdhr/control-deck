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
        let candidates = root.descendants.filter { node in
            let all = node.descendants
            return all.contains { $0.role == kAXButtonRole && $0.label == "Hide Sidebar" }
                && all.contains { $0.role == kAXButtonRole && $0.label == "Workspaces" }
        }
        guard let sidebar = candidates.last else { diagnose("missing sidebar markers"); return nil }
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
    enum DiscoveryKind { case tabGroup, leaf, container }
    static func discoveryKind(role: String) -> DiscoveryKind {
        if role == kAXTabGroupRole { return .tabGroup }
        if [kAXTextAreaRole, kAXTextFieldRole, kAXStaticTextRole].contains(role) { return .leaf }
        // Chromium may retain a scrolling layout wrapper around the main Panel.
        // A scroll role alone cannot establish that this is transcript content.
        return .container
    }

    /// A targeted discovery search may prune unrelated deep branches. Success
    /// depends on finding the exact requested roots, unlike strict subtree reads.
    static func discoverStructure<Element>(
        _ root: Element, budget: Int, maxDepth: Int,
        isComplete: () -> Bool,
        visit: (Element) -> Bool,
        children: (Element) -> [Element]
    ) -> Bool {
        var stack: [(Element, Int)] = [(root, 0)]
        var visited = 0
        while let (node, depth) = stack.popLast() {
            if isComplete() { return true }
            // Reaching an unrelated depth boundary does not invalidate roots
            // found later in a sibling branch.
            guard depth <= maxDepth else { continue }
            guard visited < budget else { return false }
            visited += 1
            guard visit(node) else { continue }
            if isComplete() { return true }
            stack.append(contentsOf: children(node).reversed().map { ($0, depth + 1) })
        }
        return isComplete()
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
        // Discover the sidebar and first main tab group in layout order. Stop
        // before its following transcript; editable text never participates.
        var sidebarRoot: AXUIElement?
        var tabRoots: [AXUIElement] = []
        let discoveryComplete = discoverStructure(window, budget: 1200, maxDepth: 18,
            isComplete: { sidebarRoot != nil && !tabRoots.isEmpty }, visit: { node in
            let role = string(node, kAXRoleAttribute)
            switch discoveryKind(role: role) {
            case .tabGroup:
                // The main conversation tab group precedes the optional Apps
                // pane in Cursor's layout. Scope to that first external group;
                // its accessible name need not be exposed as AXTitle/Description.
                tabRoots.append(node)
                return false
            case .leaf: return false
            case .container: break
            }
            if sidebarRoot == nil, role == kAXButtonRole, label(node) == "Hide Sidebar" {
                // The marker's nearest enclosing branch also needs Workspaces.
                var candidate: AXUIElement? = element(node, kAXParentAttribute)
                for _ in 0..<10 {
                    guard let branch = candidate else { break }
                    var found = false
                    var localComplete = true
                    walk(branch, budget: 1500, complete: &localComplete) { child in
                        if string(child, kAXRoleAttribute) == kAXButtonRole && label(child) == "Workspaces" { found = true; return false }
                        return !found
                    }
                    if found && localComplete { sidebarRoot = branch; break }
                    candidate = element(branch, kAXParentAttribute)
                }
                if let sidebarRoot, CFEqual(sidebarRoot, node) { return false }
            }
            return true
        }, children: { node in
            // Once its marker resolves the sidebar ancestor, no further sidebar
            // discovery is needed; its selected subtree is read strictly below.
            if let sidebarRoot, CFEqual(node, sidebarRoot) { return [] }
            return (attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? []).filter { child in
                sidebarRoot.map { !CFEqual(child, $0) } ?? true
            }
        })
        guard discoveryComplete, let sidebarRoot, !tabRoots.isEmpty else {
            diagnose("discovery complete=\(discoveryComplete) sidebar=\(sidebarRoot != nil) tabs=\(tabRoots.count)")
            return nil
        }
        let tree = Node(id: -1, role: kAXWindowRole, children:
            [read(sidebarRoot, depth: 0)] + tabRoots.map { read($0, depth: 0) })
        let remembered = folded.flatMap { CFEqual($0.window, window) ? $0 : nil }
        guard complete else { diagnose("materialization limit nodes=\(count)"); return nil }
        guard let parsed = parse(tree, rememberedCurrent: remembered?.current, diagnose: diagnose) else { return nil }
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
        _ = AXUIElementPerformAction(target, kAXPressAction as CFString)
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
