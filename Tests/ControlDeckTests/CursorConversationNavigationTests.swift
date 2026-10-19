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
    static func headerForWrapped() -> N {
        node(kAXGroupRole, children: [node(kAXButtonRole, "Wrapped Workspace", sortable: true), button("New Agent")])
    }
    static func tree(_ workspaces: [N], current: String, pinned: [String] = ["Pinned Chat"]) -> N {
        var sidebar = node(kAXGroupRole, children: [button("Hide Sidebar"), button("Projects"),
            node(kAXGroupRole, children: [button("Pinned"), list(pinned)]), button("Workspaces")]
            + workspaces)
        sidebar.domClasses = ["ui-sidebar"]
        return node(kAXWindowRole, children: [sidebar, node(kAXTabGroupRole, "Tabs", children: [node(kAXRadioButtonRole, current, selected: true)])])
    }
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }
    static func main() throws {
        // Exercise the production semantic BFS against Cursor's observed
        // sidebar / Panel / optional Apps hierarchy with hidden AX wrappers.
        var semanticSidebar = node(kAXGroupRole, children: [button("Hide Sidebar"), button("Workspaces"),
            node(kAXTabGroupRole, "Unrelated sidebar tabs")])
        semanticSidebar.domClasses = ["ui-sidebar"]
        var semanticTab = node(kAXGroupRole, "Chats", children: [node(kAXRadioButtonRole, "Observed Current", selected: true)])
        semanticTab.domClasses = ["ui-tab-system-tabs__viewport"]
        let unrelatedRoleTab = node(kAXTabGroupRole, "Unrelated nested group")
        var panelBody = node(kAXGroupRole, children: [unrelatedRoleTab, semanticTab, node(kAXGroupRole, "transcript")])
        for _ in 0..<24 { panelBody = node(kAXScrollAreaRole, children: [panelBody]) }
        // Cursor mounts the entire agent panel, including its tabs, inside
        // the tiling content host; it is not a transcript-only boundary.
        panelBody.domClasses = ["ui-tiling-panel-content"]
        var semanticPanel = node(kAXGroupRole, "Panel", children: [panelBody])
        semanticPanel.domClasses = ["ui-tiling-panel"]
        let appsTab = node(kAXTabGroupRole, "Tabs", children: [node(kAXRadioButtonRole, "Changes", selected: true)])
        let observedLayout = node(kAXWindowRole, "Cursor Agents", children: [semanticSidebar, semanticPanel,
            node(kAXGroupRole, "Pane", children: [appsTab])])
        let roots = CursorConversationNavigation.semanticRoots(observedLayout,
            classes: { $0.domClasses }, role: { $0.role }, label: { $0.label }, children: { $0.children })
        require(roots.sidebar?.id == semanticSidebar.id && roots.panel?.id == semanticPanel.id,
                "Semantic roots stay scoped despite unrelated sidebar and Apps branches")
        require(roots.tab?.id == semanticTab.id, "Source-defined tab viewport outranks earlier generic tab group and survives wrappers beyond depth18")
        require(!roots.budgetExhausted && roots.depthPruned == 0, "Observed semantic layout fits bounded BFS")
        var appsViewport = node(kAXTabGroupRole, "Apps", children: [node(kAXRadioButtonRole, "Changes", selected: true)])
        appsViewport.domClasses = ["ui-tab-system-tabs__viewport"]
        var appsPanel = node(kAXGroupRole, "Pane", children: [appsViewport])
        appsPanel.domClasses = ["ui-tiling-panel"]
        // The Apps panel is first and shallower, while the actual Chats tab
        // lives behind 24 wrappers. The old first-panel BFS selected Changes.
        let withApps = node(kAXWindowRole, children: [appsPanel, semanticSidebar, semanticPanel])
        let chatRoots = CursorConversationNavigation.semanticRoots(withApps,
            classes: { $0.domClasses }, role: { $0.role }, label: { $0.label }, children: { $0.children })
        require(chatRoots.panel?.id == semanticPanel.id && chatRoots.tab?.id == semanticTab.id && chatRoots.chatPanels == 1,
                "A shallower Apps panel never supplies the current chat tab")
        let appsOnly = CursorConversationNavigation.semanticRoots(node(kAXWindowRole, children: [semanticSidebar, appsPanel]),
            classes: { $0.domClasses }, role: { $0.role }, label: { $0.label }, children: { $0.children })
        require(appsOnly.tab == nil, "Apps cannot substitute for a missing Chats panel")
        let multipleChats = CursorConversationNavigation.semanticRoots(node(kAXWindowRole, children: [semanticSidebar, semanticPanel, semanticPanel]),
            classes: { $0.domClasses }, role: { $0.role }, label: { $0.label }, children: { $0.children })
        require(multipleChats.chatPanels == 2 && multipleChats.tab == nil,
                "Multiple Chats panels fail safely rather than choosing the first")
        let normalized = CursorConversationNavigation.normalizedTabRoot(roots.tab!)
        require(normalized.role == kAXTabGroupRole && normalized.children[0].selected,
                "Normalize only identified viewport so selected tab can be parsed")
        let exhausted = CursorConversationNavigation.semanticRoots(observedLayout, budget: 1,
            classes: { $0.domClasses }, role: { $0.role }, label: { $0.label }, children: { $0.children })
        require(exhausted.budgetExhausted && exhausted.tab == nil, "Discovery budget fails safely before roots are found")
        let bounded = CursorConversationNavigation.semanticRoots(observedLayout, maxDepth: 18,
            classes: { $0.domClasses }, role: { $0.role }, label: { $0.label }, children: { $0.children })
        require(bounded.tab == nil && bounded.depthPruned > 0, "Depth bound remains effective")
        let absentClasses = node(kAXWindowRole, children: [button("Hide Sidebar"), button("Workspaces"), appsTab])
        let absent = CursorConversationNavigation.semanticRoots(absentClasses,
            classes: { $0.domClasses }, role: { $0.role }, label: { $0.label }, children: { $0.children })
        require(absent.sidebar == nil && absent.panel == nil && absent.tab == nil, "Markers alone never select broad arbitrary ancestors")
        // Authorized raw metadata probe: window depth0, ui-sidebar depth12,
        // ui-tiling-panel depth15, tab viewport AXTabGroup depth19, selected
        // AXRadioButton depth20. CUA flattens these otherwise hidden wrappers.
        func wrap(_ child: N, count: Int) -> N {
            (0..<count).reduce(child) { wrapped, _ in node(kAXGroupRole, children: [wrapped]) }
        }
        var observedPrimary = button("Probe Current")
        observedPrimary.domClasses = ["ui-sidebar-menu-button-trigger"]
        var observedNext = button("Probe Next")
        observedNext.domClasses = ["ui-sidebar-menu-button-trigger"]
        let probeRows = node(kAXListRole, children: [
            node(kAXGroupRole, children: [wrap(observedPrimary, count: 2), button("Pin"), button("Archive")]),
            node(kAXGroupRole, children: [wrap(observedNext, count: 2), button("Pin"), button("Archive")])])
        var probeSidebar = node(kAXGroupRole, children: [button("Hide Sidebar"), button("Workspaces"),
            node(kAXButtonRole, "Probe Workspace", sortable: true), button("New Agent"), wrap(probeRows, count: 1)])
        probeSidebar.domClasses = ["ui-sidebar"]
        let selectedRadio = node(kAXRadioButtonRole, "Probe Current", selected: true)
        var probeTabs = node(kAXTabGroupRole, "Chats", children: [selectedRadio])
        probeTabs.domClasses = ["ui-tab-system-tabs__viewport"]
        var probePanel = node(kAXGroupRole, "Panel", children: [wrap(probeTabs, count: 3)])
        probePanel.domClasses = ["ui-tiling-panel"]
        let depth11Hub = node(kAXGroupRole, children: [probeSidebar, wrap(probePanel, count: 3)])
        let probeLayout = node(kAXWindowRole, children: [wrap(depth11Hub, count: 10)])
        func depth(of id: Int, in root: N, at value: Int = 0) -> Int? {
            if root.id == id { return value }
            for child in root.children { if let found = depth(of: id, in: child, at: value + 1) { return found } }
            return nil
        }
        require(depth(of: probeSidebar.id, in: probeLayout) == 12 && depth(of: probePanel.id, in: probeLayout) == 15,
                "Fixture matches measured sidebar and Panel depths")
        require(depth(of: probeTabs.id, in: probeLayout) == 19 && depth(of: selectedRadio.id, in: probeLayout) == 20,
                "Fixture reproduces definitive old depth18 cutoff failure")
        let probeRoots = CursorConversationNavigation.semanticRoots(probeLayout,
            classes: { $0.domClasses }, role: { $0.role }, label: { $0.label }, children: { $0.children })
        require(probeRoots.sidebar?.id == probeSidebar.id && probeRoots.panel?.id == probePanel.id && probeRoots.tab?.id == probeTabs.id,
                "Production semantic BFS recognizes exact authorized-probe hierarchy")
        let probeReadTree = node(kAXWindowRole, children: [probeRoots.sidebar!, CursorConversationNavigation.normalizedTabRoot(probeRoots.tab!)])
        let probeParsed = CursorConversationNavigation.parse(probeReadTree)!
        require(probeParsed.current == "Probe Current" && probeParsed.rows.map(\.label) == ["Probe Current", "Probe Next"],
                "Production parser retains wrapped primary rows and verifies exact selected radio title")
        require(try! CursorConversationNavigation.adjacentIndex(order: probeParsed.anchors.map(\.label), visible: probeParsed.rows.map(\.label), current: probeParsed.current, offset: 1) == 1,
                "Measured structure resolves next eligible conversation")
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
        // Real AX descendants can retain presentation wrappers omitted by the
        // human-readable CUA tree. Source-defined primary trigger classes must
        // survive those wrappers without capturing action buttons.
        var markedTitle = button("Wrapped Current")
        markedTitle.domClasses = ["ui-sidebar-menu-button-trigger", "ui-button"]
        var markedMore = button("More")
        markedMore.domClasses = ["ui-sidebar-menu-button-trigger"]
        let wrappedRow = node("AXUnknown", children: [node(kAXGroupRole, children: [markedTitle]),
            node("AXUnknown", children: [button("Pin"), button("Archive"), button("Unrelated accessory")])])
        let wrappedList = node(kAXListRole, children: [node("AXUnknown", children: [wrappedRow]), markedMore])
        let wrappedParsed = CursorConversationNavigation.parse(tree([headerForWrapped(), wrappedList], current: "Wrapped Current"))!
        require(wrappedParsed.anchors.map(\.label) == ["Pinned Chat", "Wrapped Current"], "DOM primary trigger marker ignores nested action buttons and More")
        let noMetadata = node(kAXListRole, children: [node("AXUnknown", children: [
            node(kAXGroupRole, children: [button("Fallback title")]),
            node("AXUnknown", children: [button("Pin"), button("Archive")])])])
        require(CursorConversationNavigation.conversationButtons(in: noMetadata).map(\.label) == ["Fallback title"], "Accessory row signature tolerates nested opaque wrappers without DOM metadata")
        require(CursorConversationNavigation.conversationButtons(in: list(["More"])).isEmpty, "More and accessory buttons never become a conversation")
        let arbitrary = node(kAXListRole, children: [node(kAXGroupRole, children: [button("Dangerous action")])])
        require(CursorConversationNavigation.conversationButtons(in: arbitrary).isEmpty, "Unmarked arbitrary list buttons require conversation row evidence")
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
