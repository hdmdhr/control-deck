import Foundation

@main
struct ActionSelectionCatalogTests {
    static func main() {
        func expect(_ condition: Bool, _ message: String) {
            guard condition else { fatalError(message) }
        }
        func relevantActions(_ kind: ProfileKind) -> [MappedAction] {
            let profile = ControllerProfile.defaults.first { $0.kind == kind }!
            return ActionSelectionCatalog.categories(for: profile, relevantOnly: true)
                .flatMap { ActionSelectionCatalog.actions(in: $0, for: profile, relevantOnly: true) }
        }
        let allCategories = ActionSelectionCatalog.categories(for: nil, relevantOnly: false)
        let allActions = allCategories.flatMap { ActionSelectionCatalog.actions(in: $0) }
        expect(Set(allActions) == Set(MappedAction.allCases), "all actions must be selectable")
        expect(allActions.count == Set(allActions).count, "no action appears twice in all categories")
        expect(Set(allCategories).count == allCategories.count, "all categories are unique")

        for kind in [ProfileKind.cursor, .grokBot, .slack] {
            let actions = relevantActions(kind)
            expect(actions.contains(.none), "each relevant scope includes unassigned")
            expect(actions.contains(.systemDictation), "each relevant scope includes universal dictation")
            expect(actions.contains(.copy) && actions.contains(.paste), "shared editing actions remain available")
        }
        let cursor = relevantActions(.cursor)
        expect(cursor.contains(.cursorDictation) && cursor.contains(.cursorNextConversation), "Cursor scope includes native actions")
        expect(cursor.contains(.assistantSend) && cursor.contains(.assistantRightPanel), "Cursor scope includes shared assistant actions")
        expect(!cursor.contains(.grokNextBot), "Cursor scope excludes unrelated Grok actions")
        let grok = relevantActions(.grokBot)
        expect(grok.contains(.grokDictation) && grok.contains(.grokNextBot), "Grok scope includes native actions")
        expect(grok.contains(.assistantSend) && grok.contains(.assistantRightPanel), "Grok scope includes shared assistant actions")
        let browser = relevantActions(.chrome)
        expect(browser.contains(.codexAppSnapshot) && !browser.contains(.codexSend),
               "global snapshot stays visible without exposing unrelated Codex actions in other profiles")
        let slack = relevantActions(.slack)
        expect(slack.contains(.slackThreads) && slack.contains(.slackHuddle), "Slack scope exposes all native Slack actions")
        expect(!slack.contains(.cursorNextConversation), "Slack scope excludes unrelated Cursor actions")

        expect(ActionSelectionCatalog.matches(.codexSend, query: "ChatGPT"), "Codex actions can be searched by ChatGPT alias")
        expect(ActionSelectionCatalog.matches(.codexSend, query: "OpenAI"), "Codex actions support app aliases")
        expect(ActionSelectionCatalog.matches(.assistantSend, query: "Cursor"), "shared assistant action searchable by Cursor")
        expect(ActionSelectionCatalog.matches(.assistantRightPanel, query: "Grok Bot"), "shared assistant action searchable by Grok Bot")
        expect(ActionSelectionCatalog.matches(.copy, query: ActionCategory.keyboard.label), "localized category is searchable")
        expect(ActionSelectionCatalog.matches(.cursorDictation, query: "  Cursor  "), "search trims whitespace")
        expect(!ActionSelectionCatalog.matches(.copy, query: "unlikely-nonexistent-action"), "empty result remains possible")
        expect(ActionSelectionCatalog.matches(.none, query: ""), "empty query includes none")

        var custom = ControllerProfile.general
        custom.setAction(.grokNextBot, for: .triangle)
        let customCategories = ActionSelectionCatalog.categories(for: custom, relevantOnly: true)
        expect(customCategories.contains(.grokBot), "existing nonpreferred binding remains visible in relevant scope")
        expect(Set(customCategories).count == customCategories.count, "preferred and assigned category overlap is deduplicated")
        custom.setAction(.none, for: .triangle)
        custom.touchpad.setAction(.slackHuddle, for: .twoFingerLongPress)
        custom.gyro.setAction(.grokNextBot, for: .shake)
        let gestureCategories = ActionSelectionCatalog.categories(for: custom, relevantOnly: true)
        expect(gestureCategories.contains(.slack) && gestureCategories.contains(.grokBot),
               "actions assigned only to touchpad or motion remain visible in relevant scope")
        print("PASS: action catalog completeness, relevant profiles, shared actions and search")
    }
}
