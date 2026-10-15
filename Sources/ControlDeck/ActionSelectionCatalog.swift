import Foundation

/// Shared by the mapping inspector and the action pickers in settings.
enum ActionSelectionCatalog {
    static func actions(
        in category: ActionCategory,
        for profile: ControllerProfile? = nil,
        relevantOnly: Bool = false
    ) -> [MappedAction] {
        let actions = MappedAction.allCases.filter { $0.category == category }
        guard relevantOnly, let profile,
              !profile.kind.preferredActionCategories.contains(category) else { return actions }
        let assigned = Set(ControllerInput.allCases.map { profile.action(for: $0) } +
            TouchGesture.allCases.map { profile.touchpad.action(for: $0) } +
            GyroGesture.allCases.map { profile.gyro.action(for: $0) })
        return actions.filter { assigned.contains($0) }
    }

    static func categories(for profile: ControllerProfile?, relevantOnly: Bool) -> [ActionCategory] {
        guard relevantOnly, let profile else { return ActionCategory.allCases }
        let preferred = profile.kind.preferredActionCategories
        let assigned = Set(
            ControllerInput.allCases.map { profile.action(for: $0).category } +
            TouchGesture.allCases.map { profile.touchpad.action(for: $0).category } +
            GyroGesture.allCases.map { profile.gyro.action(for: $0).category }
        )
        return preferred + ActionCategory.allCases.filter { !preferred.contains($0) && assigned.contains($0) }
    }

    static func matches(_ action: MappedAction, query: String) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let aliases: String
        switch action.category {
        case .codex: aliases = "Codex ChatGPT OpenAI 同一应用 同じアプリ"
        case .cursor: aliases = "Cursor 编辑器 エディタ"
        case .grokBot: aliases = "Grok Bot"
        case .communication: aliases = "Cursor Grok Bot assistant 助手 アシスタント"
        case .mail: aliases = "Mail 邮件 メール"
        default: aliases = action.category.rawValue
        }
        let searchable = [action.label, action.rawValue, action.category.label, aliases].joined(separator: " ")
        return terms.allSatisfy { searchable.localizedStandardContains($0) }
    }
}
