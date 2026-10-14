import Combine
import Foundation

struct ProfileWheelSlot: Codable, Equatable, Identifiable, Sendable {
    let position: Int
    var profileKind: ProfileKind

    var id: Int { position }

    var positionLabel: String {
        switch position {
        case 0: String(localized: "Top", bundle: AppResources.localizationBundle)
        case 1: String(localized: "Upper right", bundle: AppResources.localizationBundle)
        case 2: String(localized: "Right", bundle: AppResources.localizationBundle)
        case 3: String(localized: "Lower right", bundle: AppResources.localizationBundle)
        case 4: String(localized: "Bottom", bundle: AppResources.localizationBundle)
        case 5: String(localized: "Lower left", bundle: AppResources.localizationBundle)
        case 6: String(localized: "Left", bundle: AppResources.localizationBundle)
        case 7: String(localized: "Upper left", bundle: AppResources.localizationBundle)
        default: String(localized: "Slot \(position + 1)", bundle: AppResources.localizationBundle)
        }
    }

    static let defaults: [ProfileWheelSlot] = [
        .init(position: 0, profileKind: .codex),
        .init(position: 1, profileKind: .chrome),
        .init(position: 2, profileKind: .cursor),
        .init(position: 3, profileKind: .grokBot),
        .init(position: 4, profileKind: .general),
        .init(position: 5, profileKind: .finder),
        .init(position: 6, profileKind: .terminal),
        .init(position: 7, profileKind: .slack)
    ]
}

@MainActor
final class ShiftLayerStore: ObservableObject {
    @Published private(set) var profileSlots: [ProfileWheelSlot]

    static let storageKey = "profileWheelSettings.v1"
    private static let assistantWheelMigrationKey = "assistantProfileWheel.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(
               [ProfileWheelSlot].self,
               from: data
           ) {
            let migrated = defaults.bool(forKey: Self.assistantWheelMigrationKey)
                ? decoded : Self.migrateLegacyDefaults(decoded)
            profileSlots = Self.merged(migrated)
        } else {
            profileSlots = ProfileWheelSlot.defaults
        }
        defaults.set(true, forKey: Self.assistantWheelMigrationKey)
        persist()
    }

    func slot(at position: Int) -> ProfileWheelSlot {
        profileSlots.first(where: { $0.position == position }) ??
            ProfileWheelSlot.defaults[position]
    }

    func setProfile(_ kind: ProfileKind, at position: Int) {
        guard let targetIndex = profileSlots.firstIndex(where: {
            $0.position == position
        }) else { return }
        guard profileSlots[targetIndex].profileKind != kind else { return }

        let displaced = profileSlots[targetIndex].profileKind
        if let existingIndex = profileSlots.firstIndex(where: {
            $0.profileKind == kind
        }) {
            profileSlots[existingIndex].profileKind = displaced
        }
        profileSlots[targetIndex].profileKind = kind
        persist()
    }

    func reset() {
        profileSlots = ProfileWheelSlot.defaults
        persist()
    }

    func reloadExternalChanges() {
        defaults.synchronize()
        guard let data = defaults.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode(
                  [ProfileWheelSlot].self,
                  from: data
              )
        else {
            return
        }
        let merged = Self.merged(decoded)
        guard merged != profileSlots else { return }
        profileSlots = merged
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(profileSlots) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    /// Upgrade only unchanged legacy slots, leaving reordered or custom slots intact.
    static func migrateLegacyDefaults(_ saved: [ProfileWheelSlot]) -> [ProfileWheelSlot] {
        var result = saved
        for (position, legacy, replacement) in [(2, ProfileKind.claude, ProfileKind.cursor), (3, .spotify, .grokBot)] {
            guard !result.contains(where: { $0.profileKind == replacement }),
                  let index = result.firstIndex(where: { $0.position == position && $0.profileKind == legacy })
            else { continue }
            result[index].profileKind = replacement
        }
        return result
    }

    private static func merged(
        _ saved: [ProfileWheelSlot]
    ) -> [ProfileWheelSlot] {
        ProfileWheelSlot.defaults.map { fallback in
            guard let savedSlot = saved.first(where: {
                $0.position == fallback.position
            }), ProfileKind.allCases.contains(savedSlot.profileKind)
            else {
                return fallback
            }
            return savedSlot
        }
    }
}

struct RadialProfileSelector: Sendable {
    private(set) var selectedIndex: Int?
    let activationThreshold: Float
    let neutralThreshold: Float

    init(
        activationThreshold: Float = 0.48,
        neutralThreshold: Float = 0.28
    ) {
        self.activationThreshold = activationThreshold
        self.neutralThreshold = neutralThreshold
    }

    mutating func update(x: Float, y: Float) -> Int? {
        let magnitude = sqrt((x * x) + (y * y))
        if magnitude <= neutralThreshold {
            selectedIndex = nil
            return nil
        }
        guard magnitude >= activationThreshold else { return selectedIndex }

        var angle = atan2(Double(x), Double(y))
        if angle < 0 { angle += 2 * .pi }
        selectedIndex = Int(
            floor((angle + (.pi / 8)) / (.pi / 4))
        ) % 8
        return selectedIndex
    }

    mutating func reset() {
        selectedIndex = nil
    }
}

enum ReasoningStep: Equatable, Sendable {
    case smarter
    case faster

    var title: String {
        switch self {
        case .smarter: String(localized: "Smarter", bundle: AppResources.localizationBundle)
        case .faster: String(localized: "Faster", bundle: AppResources.localizationBundle)
        }
    }
}

struct SteppedStickGate: Sendable {
    private(set) var armed = true
    let activationThreshold: Float
    let neutralThreshold: Float

    init(
        activationThreshold: Float = 0.62,
        neutralThreshold: Float = 0.28
    ) {
        self.activationThreshold = activationThreshold
        self.neutralThreshold = neutralThreshold
    }

    mutating func update(y: Float) -> ReasoningStep? {
        if abs(y) <= neutralThreshold {
            armed = true
            return nil
        }
        guard armed, abs(y) >= activationThreshold else { return nil }
        armed = false
        return y > 0 ? .smarter : .faster
    }

    mutating func reset() {
        armed = true
    }
}

enum TaskSelection {
    static func adjacentID(
        in tasks: [RecentCodexTask],
        selectedID: String?,
        offset: Int
    ) -> String? {
        guard !tasks.isEmpty else { return nil }
        guard let selectedID,
              let current = tasks.firstIndex(where: { $0.id == selectedID })
        else {
            return tasks[0].id
        }
        let count = tasks.count
        return tasks[(current + offset + count) % count].id
    }
}
