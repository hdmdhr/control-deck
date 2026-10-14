import Foundation
import ApplicationServices

@main struct CursorConversationNavigationTests {
    typealias N = CursorConversationNavigation.Node
    static var counter = 0
    static func node(_ role: String, _ label: String = "", children: [N] = [], selected: Bool = false,
                     sortable: Bool = false, expanded: Bool? = nil, advertised: Bool = false) -> N {
        counter += 1
        return N(id: counter, role: role, label: label, roleDescription: sortable ? "sortable" : "",
                 selected: selected, advertisedAttributes: advertised ? [kAXExpandedAttribute] : [],
                 expandedValue: expanded, children: children)
    }
    static func button(_ name: String) -> N { node(kAXButtonRole, name, expanded: false) }
    static func row(_ name: String) -> N {
        node(kAXGroupRole, children: [node(kAXImageRole, "Completed"), button(name), node(kAXStaticTextRole, "1m"), button("Pin"), button("Archive")])
    }
    static func list(_ names: [String]) -> N { node(kAXListRole, children: names.map(row) + [button("More")]) }
    static func workspace(_ name: String, names: [String], expanded: Bool, retained: [String] = []) -> N {
        // Chromium exposes false on the sortable header and every ordinary button.
        // Only the empty disclosure child advertises the attribute.
        let trigger = node(kAXButtonRole, expanded: expanded, advertised: true)
        let header = node(kAXButtonRole, name, children: [trigger], sortable: true, expanded: false)
        return node(kAXGroupRole, children: [node(kAXGroupRole, children: [header, button("New Agent")])]
            + (retained.isEmpty ? [] : [list(retained)]) + (expanded ? [list(names)] : []))
    }
    static func tree(_ workspaces: [N], current: String, pinned: [String] = ["Pinned Chat"]) -> N {
        let sidebar = node(kAXGroupRole, children: [button("Hide Sidebar"), button("Projects"),
            node(kAXGroupRole, children: [button("Pinned"), list(pinned)]), button("Workspaces")]
            + workspaces)
        return node(kAXWindowRole, children: [sidebar, node(kAXTabGroupRole, "Tabs", children: [node(kAXRadioButtonRole, current, selected: true)])])
    }
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }
    static func main() throws {
        let expanded = workspace("Current Workspace", names: ["First", "Current"], expanded: true, retained: [])
        let collapsed = workspace("Folded", names: ["Hidden"], expanded: false)
        let last = workspace("Last", names: ["Next"], expanded: true)
        let parsed = CursorConversationNavigation.parse(tree([expanded, collapsed, last], current: "Current"))!
        require(parsed.rows.map(\.label) == ["Pinned Chat", "First", "Current", "Next"], "Actual row structure preserves order and excludes accessories and More")
        require(parsed.workspaces.map(\.expanded) == [true, false, true], "Ignore Chromium's unadvertised false getters")
        require(parsed.workspaceByRow[parsed.rows[0].id] == nil, "Pinned has no workspace")
        require(try! CursorConversationNavigation.adjacentIndex(order: parsed.rows.map(\.label), visible: parsed.rows.map(\.label), current: "Current", offset: 1) == 3, "Skip collapsed workspace")
        let folded = tree([workspace("Current Workspace", names: [], expanded: false, retained: ["Current"]), last], current: "Current")
        let hidden = CursorConversationNavigation.parse(folded, rememberedCurrent: "Current")!
        require(hidden.rows.map(\.label) == ["Pinned Chat", "Next"], "Retained selected row in a folded workspace is an anchor, never a target")
        require(try! CursorConversationNavigation.adjacentIndex(order: ["Pinned Chat", "First", "Current", "Next"], visible: hidden.rows.map(\.label), current: "Current", offset: 1) == 1, "Hidden current anchor can reach next visible row")
        // Exact flattened CUA shape: each list is a sibling of its header
        // container, including the residual current row after manual folding.
        let headerA = node(kAXGroupRole, children: [node(kAXButtonRole, "Manual Fold", sortable: true, expanded: false), button("New Agent")])
        let headerB = node(kAXGroupRole, children: [node(kAXButtonRole, "Other", sortable: true, expanded: false), button("New Agent")])
        let flattened = CursorConversationNavigation.parse(tree([headerA, list(["Current"]), headerB, list(["Next", "Later"])], current: "Current"))!
        require(flattened.anchors.map(\.label) == ["Pinned Chat", "Current", "Next", "Later"], "Retain folded current anchor at its observed document position without cache")
        require(flattened.rows.map(\.label) == ["Pinned Chat", "Next", "Later"], "Folded workspace residual current is ineligible")
        let currentAnchor = flattened.anchors.first { $0.label == "Current" }!
        require(flattened.workspaceByRow[currentAnchor.id] == 0, "Sibling list inherits exact preceding workspace")
        require(try! CursorConversationNavigation.adjacentIndex(order: flattened.anchors.map(\.label), visible: flattened.rows.map(\.label), current: "Current", offset: 1) == 1, "Startup folded anchor navigates right without historical order")
        require(try! CursorConversationNavigation.adjacentIndex(order: flattened.anchors.map(\.label), visible: flattened.rows.map(\.label), current: "Current", offset: -1) == 0, "Startup folded anchor navigates left without historical order")
        require(CursorConversationNavigation.parse(tree([workspace("Dup", names: ["Same", "Same"], expanded: true)], current: "Same")) == nil, "Duplicate names fail safely")
        require(CursorConversationNavigation.parse(tree([expanded], current: "Unknown")) == nil, "Unknown selected tab fails safely")
        do {
            _ = try CursorConversationNavigation.adjacentIndex(order: ["Only"], visible: ["Only"], current: "Only", offset: 1)
            fatalError("Boundary should fail")
        } catch CursorConversationNavigation.SelectionError.boundary { }
        require(CursorConversationNavigation.parse(tree([expanded], current: "Current"))!.workspaces[0].expanded, "A no-op disclosure remains expanded; AXPress acceptance cannot change parsed state")
        print("PASS: Cursor conversation navigation fixtures")
    }
}
