import Foundation

struct SharedControllerProfile: Codable, Equatable, Sendable {
    static let formatIdentifier = "com.ianhansel.controldeck.profile"
    static let currentVersion = 1

    var format: String
    var version: Int
    var exportedAt: Date
    var profile: ControllerProfile

    init(profile: ControllerProfile, exportedAt: Date = Date()) {
        format = Self.formatIdentifier
        version = Self.currentVersion
        self.exportedAt = exportedAt
        self.profile = profile
    }
}

enum ProfileTransfer {
    static let maximumFileSize = 256 * 1_024

    static func encode(
        profile: ControllerProfile,
        exportedAt: Date = Date()
    ) throws -> Data {
        try validate(profile)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
            .withoutEscapingSlashes
        ]
        return try encoder.encode(
            SharedControllerProfile(profile: profile, exportedAt: exportedAt)
        )
    }

    static func decode(_ data: Data) throws -> SharedControllerProfile {
        guard data.count <= maximumFileSize else {
            throw ProfileTransferError.fileTooLarge
        }
        try validateJSONShape(data)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let shared: SharedControllerProfile
        do {
            shared = try decoder.decode(SharedControllerProfile.self, from: data)
        } catch {
            throw ProfileTransferError.invalidJSON
        }

        guard shared.format == SharedControllerProfile.formatIdentifier else {
            throw ProfileTransferError.invalidFormat
        }
        guard shared.version == SharedControllerProfile.currentVersion else {
            throw ProfileTransferError.unsupportedVersion(shared.version)
        }
        try validate(shared.profile)
        return shared
    }

    static func safeFilename(for profile: ControllerProfile) -> String {
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-_ ")
        )
        let scalars = profile.name.unicodeScalars.map {
            allowed.contains($0) ? Character(String($0)) : "-"
        }
        let base = String(scalars)
            .split(whereSeparator: { $0 == " " || $0 == "-" })
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .lowercased()
        return (base.isEmpty ? profile.kind.rawValue : base) +
            ".controldeck-profile"
    }

    static func validate(_ profile: ControllerProfile) throws {
        try validateText(profile.name, label: String(localized: "Profile name", bundle: AppResources.localizationBundle), maximumLength: 80)
        try validateTextList(
            profile.bundleIdentifiers,
            label: String(localized: "App identifiers", bundle: AppResources.localizationBundle),
            maximumCount: 64,
            maximumLength: 200
        )
        try validateTextList(
            profile.windowTitleKeywords,
            label: String(localized: "Window-title keywords", bundle: AppResources.localizationBundle),
            maximumCount: 64,
            maximumLength: 120
        )

        try validateBindings(
            profile.bindings,
            validKeys: Set(ControllerInput.allCases.map(\.rawValue)),
            label: String(localized: "button", bundle: AppResources.localizationBundle)
        )
        try validateBindings(
            profile.touchpad.gestureBindings,
            validKeys: Set(TouchGesture.allCases.map(\.rawValue)),
            label: String(localized: "touch gesture", bundle: AppResources.localizationBundle)
        )
        try validateBindings(
            profile.gyro.gestureBindings,
            validKeys: Set(GyroGesture.allCases.map(\.rawValue)),
            label: String(localized: "gyro gesture", bundle: AppResources.localizationBundle)
        )

        try validateNumber(profile.pointer.speed, in: 300...1_600, label: String(localized: "Pointer speed", bundle: AppResources.localizationBundle))
        try validateNumber(
            profile.pointer.acceleration,
            in: 1...2.6,
            label: String(localized: "Pointer acceleration", bundle: AppResources.localizationBundle)
        )
        try validateNumber(profile.pointer.deadZone, in: 0.05...0.35, label: String(localized: "Pointer dead zone", bundle: AppResources.localizationBundle))
        try validateNumber(profile.pointer.scrollSpeed, in: 300...1_800, label: String(localized: "Scroll speed", bundle: AppResources.localizationBundle))
        try validateNumber(
            profile.pointer.scrollAcceleration,
            in: 1...2.6,
            label: String(localized: "Scroll acceleration", bundle: AppResources.localizationBundle)
        )
        try validateNumber(
            profile.pointer.scrollDeadZone,
            in: 0.05...0.35,
            label: String(localized: "Scroll dead zone", bundle: AppResources.localizationBundle)
        )
        try validateNumber(
            profile.touchpad.pointerSensitivity,
            in: 0.35...2.2,
            label: String(localized: "Touchpad pointer sensitivity", bundle: AppResources.localizationBundle)
        )
        try validateNumber(
            profile.touchpad.scrollSensitivity,
            in: 0.35...2.2,
            label: String(localized: "Touchpad scroll sensitivity", bundle: AppResources.localizationBundle)
        )
        try validateNumber(profile.gyro.shakeThreshold, in: 1.4...3.6, label: String(localized: "Shake force", bundle: AppResources.localizationBundle))
        try validateNumber(profile.gyro.tiltThreshold, in: 0.45...0.88, label: String(localized: "Tilt angle", bundle: AppResources.localizationBundle))
        try validateNumber(
            profile.gyro.rotationThreshold,
            in: 1.5...6,
            label: String(localized: "Twist speed", bundle: AppResources.localizationBundle)
        )
    }

    private static func validateJSONShape(_ data: Data) throws {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            hasOnlyKeys(root, allowed: ["format", "version", "exportedAt", "profile"]),
            let profile = root["profile"] as? [String: Any],
            hasOnlyKeys(
                profile,
                allowed: [
                    "kind", "name", "bundleIdentifiers",
                    "windowTitleKeywords", "bindings", "pointer",
                    "touchpad", "gyro"
                ]
            ),
            let pointer = profile["pointer"] as? [String: Any],
            hasOnlyKeys(
                pointer,
                allowed: [
                    "source", "speed", "acceleration", "deadZone",
                    "scrollSource", "caretSource", "scrollSpeed", "scrollAcceleration",
                    "scrollDeadZone"
                ]
            ),
            let touchpad = profile["touchpad"] as? [String: Any],
            hasOnlyKeys(
                touchpad,
                allowed: [
                    "oneFingerMode", "twoFingerScroll", "naturalScrolling",
                    "pointerSensitivity", "scrollSensitivity",
                    "gestureBindings"
                ]
            ),
            let gyro = profile["gyro"] as? [String: Any],
            hasOnlyKeys(
                gyro,
                allowed: [
                    "enabled", "shakeThreshold", "tiltThreshold",
                    "rotationThreshold", "gestureBindings"
                ]
            )
        else {
            throw ProfileTransferError.invalidSchema
        }
    }

    private static func hasOnlyKeys(
        _ object: [String: Any],
        allowed: Set<String>
    ) -> Bool {
        Set(object.keys).isSubset(of: allowed)
    }

    private static func validateBindings(
        _ bindings: [String: String],
        validKeys: Set<String>,
        label: String
    ) throws {
        guard bindings.count <= validKeys.count else {
            throw ProfileTransferError.invalidValue(String(localized: "Too many \(label) bindings", bundle: AppResources.localizationBundle))
        }
        for (key, action) in bindings {
            guard validKeys.contains(key) else {
                throw ProfileTransferError.invalidValue(String(localized: "Unknown \(label): \(key)", bundle: AppResources.localizationBundle))
            }
            guard MappedAction(rawValue: action) != nil else {
                throw ProfileTransferError.invalidValue(String(localized: "Unknown action: \(action)", bundle: AppResources.localizationBundle))
            }
        }
    }

    private static func validateNumber(
        _ value: Double,
        in range: ClosedRange<Double>,
        label: String
    ) throws {
        guard value.isFinite, range.contains(value) else {
            throw ProfileTransferError.invalidValue(String(localized: "\(label) is outside the supported range", bundle: AppResources.localizationBundle))
        }
    }

    private static func validateTextList(
        _ values: [String],
        label: String,
        maximumCount: Int,
        maximumLength: Int
    ) throws {
        guard values.count <= maximumCount else {
            throw ProfileTransferError.invalidValue(String(localized: "Too many \(label.lowercased())", bundle: AppResources.localizationBundle))
        }
        for value in values {
            try validateText(value, label: label, maximumLength: maximumLength)
        }
    }

    private static func validateText(
        _ value: String,
        label: String,
        maximumLength: Int
    ) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumLength else {
            throw ProfileTransferError.invalidValue(String(localized: "\(label) is empty or too long", bundle: AppResources.localizationBundle))
        }
        guard !trimmed.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        }) else {
            throw ProfileTransferError.invalidValue(String(localized: "\(label) contains control characters", bundle: AppResources.localizationBundle))
        }
    }
}

enum ProfileTransferError: LocalizedError, Equatable {
    case fileTooLarge
    case invalidJSON
    case invalidSchema
    case invalidFormat
    case unsupportedVersion(Int)
    case invalidValue(String)

    var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            String(localized: "The profile is larger than the 256 KB safety limit.", bundle: AppResources.localizationBundle)
        case .invalidJSON:
            String(localized: "The selected file is not a valid ControlDeck JSON profile.", bundle: AppResources.localizationBundle)
        case .invalidSchema:
            String(localized: "The profile contains missing or unrecognised fields.", bundle: AppResources.localizationBundle)
        case .invalidFormat:
            String(localized: "The selected JSON file is not a ControlDeck profile.", bundle: AppResources.localizationBundle)
        case let .unsupportedVersion(version):
            String(localized: "Profile version \(version) is not supported by this version of ControlDeck.", bundle: AppResources.localizationBundle)
        case let .invalidValue(message):
            message
        }
    }
}
