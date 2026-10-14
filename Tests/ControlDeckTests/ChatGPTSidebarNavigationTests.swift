import Foundation
import AppKit
import ApplicationServices

@main struct ChatGPTSidebarNavigationTests {
    typealias N = ChatGPTSidebarNavigation.Node
    static let marker = "data-[app-action-sidebar-thread-selected=true]:bg-primary-ghost-hover"
    static func chat(_ id: Int, _ title: String, current: Bool = false) -> N {
        N(id: id, role: kAXButtonRole, classes: ["sidebar-item", marker], label: title, current: current)
    }
    static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fatalError(message) }
    }
    static func main() throws {
        let activeTitle = N(id: 30, role: kAXGroupRole,
            classes: ["flex", "text-base", "leading-5", "text-[var(--color-text)]"])
        let inactiveTitle = N(id: 31, role: kAXGroupRole,
            classes: ["flex", "text-base", "leading-5", "text-default"])
        require(ChatGPTSidebarNavigation.isCurrent(ariaCurrent: "", descendants: [activeTitle]), "Missing AXARIA current uses source-backed active title")
        require(!ChatGPTSidebarNavigation.isCurrent(ariaCurrent: "", descendants: [inactiveTitle]), "Inactive title stays inactive")
        require(ChatGPTSidebarNavigation.isCurrent(ariaCurrent: "false", descendants: [activeTitle]), "Active title also works with a false AX default")
        let menuOpenRow = N(id: 32, role: kAXButtonRole, classes: ["sidebar-item", "bg-primary-ghost-hover", "hover:bg-primary-ghost-hover"], children: [inactiveTitle])
        require(!ChatGPTSidebarNavigation.isCurrent(ariaCurrent: "", descendants: [menuOpenRow]), "Menu-open background is not selection")
        require(ChatGPTSidebarNavigation.isCurrent(ariaCurrent: "page", descendants: []), "ARIA current continues working")
        let nestedConversation = N(id: 33, role: kAXButtonRole, classes: ["sidebar-item", marker], label: "nested", children: [activeTitle])
        require(!ChatGPTSidebarNavigation.isCurrent(ariaCurrent: "", descendants: [nestedConversation]), "Do not borrow another conversation selection")
        var colored = chat(40, "Active")
        colored.classes.append("bg-primary-ghost-hover")
        require(ChatGPTSidebarNavigation.rows(in: colored).first!.node.current, "Observed unique background works when AX omits title containers")
        var hovered = chat(41, "Hovered")
        hovered.classes.append("hover:bg-primary-ghost-hover")
        require(!ChatGPTSidebarNavigation.rows(in: hovered).first!.node.current, "Hover variant token is not selected")
        var openMenu = colored
        openMenu.children = [N(id: 42, role: kAXPopUpButtonRole, expanded: true)]
        require(!ChatGPTSidebarNavigation.rows(in: openMenu).first!.node.current, "Open row menu suppresses background fallback")
        var another = colored
        another.id = 43; another.label = "Other"
        require(!ChatGPTSidebarNavigation.rows(in: N(id: 44, role: kAXGroupRole, children: [colored, another])).contains { $0.node.current }, "Ambiguous background rows fail without clicking")
        let viewport = CGRect(x: 0, y: 40, width: 300, height: 400)
        let partial = ChatGPTSidebarNavigation.visibleRect(frame: CGRect(x: 0, y: 20, width: 300, height: 50), window: CGRect(x: 0, y: 0, width: 1000, height: 800), clips: [viewport])
        require(partial == CGRect(x: 0, y: 40, width: 300, height: 30), "Partially clipped row uses visible portion, still requires live hit test")
        require(ChatGPTSidebarNavigation.visibleRect(frame: CGRect(x: 0, y: 0, width: 300, height: 20), window: viewport, clips: []) == nil, "Offscreen rows never supply click coordinates")
        let root = N(id: 0, role: kAXGroupRole, children: [
            chat(1, "Pinned", current: true),
            N(id: 2, role: kAXButtonRole, classes: ["sidebar-item"], label: "Project", children: [chat(3, "Project chat")]),
            N(id: 4, role: kAXButtonRole, classes: ["sidebar-item"], label: "Folded", expanded: false, children: [chat(5, "Hidden")]),
            N(id: 6, role: kAXButtonRole, classes: ["sidebar-item"], label: "Show more"),
            chat(7, "Recent"), chat(8, "Project chat"), chat(9, "Pinned", current: true)
        ])
        let rows = ChatGPTSidebarNavigation.rows(in: root)
        require(rows.map(\.node.id) == [1,3,7,8,9], "Read rendered sidebar order; exclude project headers, More, hidden children")
        require(rows[1].occurrence != rows[3].occurrence, "Same title occurrences are distinct")
        require(try! ChatGPTSidebarNavigation.adjacentIndex(rows: rows, remembered: nil, offset: 1) == 1, "Initial duplicate active rows use first occurrence")
        require(try! ChatGPTSidebarNavigation.adjacentIndex(rows: rows, remembered: rows[4].occurrence, offset: -1) == 3, "Remember last navigated occurrence")
        let adjacentDuplicates = ChatGPTSidebarNavigation.rows(in: N(id: 0, role: kAXGroupRole, children: [chat(1,"Same",current:true),chat(2,"Same",current:true),chat(3,"Other")]))
        require(try! ChatGPTSidebarNavigation.adjacentIndex(rows: adjacentDuplicates, remembered: nil, offset: 1) == 2, "Do not claim switching to an already selected duplicate")
        do {
            _ = try ChatGPTSidebarNavigation.adjacentIndex(rows: rows, remembered: nil, offset: -1)
            fatalError("Must stop at list boundary")
        } catch ChatGPTSidebarNavigation.SelectionError.boundary { }
        do {
            _ = try ChatGPTSidebarNavigation.adjacentIndex(rows: ChatGPTSidebarNavigation.rows(in: chat(1,"No current")), remembered: nil, offset: 1)
            fatalError("Missing aria-current must not click")
        } catch ChatGPTSidebarNavigation.SelectionError.unavailable { }
        print("PASS: ChatGPT sidebar navigation fixtures")
    }
}
