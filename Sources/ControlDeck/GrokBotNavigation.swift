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

    @MainActor
    static func navigate(offset: Int) -> (succeeded: Bool, message: String) {
        guard AXIsProcessTrusted() else {
            return (false, String(localized: "Accessibility permission is required for controller actions", bundle: AppResources.localizationBundle))
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == "com.anysphere.sand" else {
            return (false, String(localized: "Bring Grok Bot to the foreground to switch bots", bundle: AppResources.localizationBundle))
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = element(root, kAXFocusedWindowAttribute) else {
            return (false, String(localized: "Grok Bot focused window is unavailable", bundle: AppResources.localizationBundle))
        }
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
            return (false, String(localized: "Grok Bot sidebar is unavailable or ambiguous", bundle: AppResources.localizationBundle))
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
            return (false, String(localized: "Grok Bot sidebar is unavailable or ambiguous", bundle: AppResources.localizationBundle))
        }
        let selectedNames = zip(buttons, names).compactMap { button, name in
            (attribute(button, kAXSelectedAttribute) as? Bool) == true ? name : nil
        }
        do {
            let index = try adjacentIndex(names: names, currentNames: headings + selectedNames, offset: offset)
            // Recheck focus immediately before pressing; never activate another application/window.
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
                  let focused = element(root, kAXFocusedWindowAttribute), CFEqual(window, focused) else {
                return (false, String(localized: "Grok Bot focus changed; try again", bundle: AppResources.localizationBundle))
            }
            guard AXUIElementPerformAction(buttons[index], kAXPressAction as CFString) == .success else {
                return (false, String(localized: "Grok Bot could not switch bots", bundle: AppResources.localizationBundle))
            }
            return (true, String(localized: "Grok Bot switched bots", bundle: AppResources.localizationBundle))
        } catch SelectionError.boundary {
            return (false, String(localized: "Grok Bot has no adjacent bot in this direction", bundle: AppResources.localizationBundle))
        } catch {
            return (false, String(localized: "Grok Bot current bot is unavailable or ambiguous", bundle: AppResources.localizationBundle))
        }
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
