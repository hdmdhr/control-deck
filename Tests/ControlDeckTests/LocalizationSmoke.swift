import Foundation

@main
struct LocalizationSmoke {
    static func main() throws {
        let language = CommandLine.arguments[1]
        let expected: (ready: String, general: String, connected: String, left: String)
        switch language {
        case "zh-Hans": expected = ("就绪", "通用 macOS", "DualSense 已连接", "左摇杆")
        case "ja": expected = ("準備完了", "macOS 全般", "DualSense に接続しました", "左スティック")
        default: expected = ("Ready", "General macOS", "DualSense connected", "Left stick")
        }
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("\(language): \(message)") }
        }
        // Exercise the same nested bundle lookup used in production models/statuses.
        check(String(localized: "Ready", bundle: AppResources.localizationBundle) == expected.ready,
              "model/status language selection")
        let device = "DualSense"
        check(String(localized: "\(device) connected", bundle: AppResources.localizationBundle) == expected.connected,
              "interpolated status must retain its argument")
        check(ControllerStick.left.label == expected.left, "model label")
        check(ControllerProfile.general.displayName == expected.general, "built-in profile display name")
        // Native SwiftUI literals resolve through the app's main bundle.
        check(Bundle.main.localizedString(forKey: "Ready", value: nil, table: nil) == expected.ready,
              "main-bundle SwiftUI table")
        check(ControllerProfile.general.name == "General macOS", "stored profile names must not change")
        check(MappedAction.codexSend.rawValue == "codexSend", "action identifiers must not change")
        var custom = ControllerProfile.general
        custom.name = "私の配置 / 我的配置"
        check(custom.displayName == custom.name, "custom names must remain verbatim")
        let data = try JSONEncoder().encode(custom)
        let decoded = try JSONDecoder().decode(ControllerProfile.self, from: data)
        check(decoded == custom, "profile round trip")
        check(String(localized: "Untranslated fallback", bundle: AppResources.localizationBundle) == "Untranslated fallback",
              "missing-key fallback")
        try validateTables(check: check)
        print("PASS: \(language) app + model localization, interpolation, profile compatibility and catalog integrity")
    }

    private static func validateTables(check: (@autoclosure () -> Bool, String) -> Void) throws {
        let bundle = AppResources.localizationBundle
        func table(_ language: String, _ name: String) throws -> [String: String] {
            let url = bundle.url(forResource: name, withExtension: "strings", subdirectory: nil, localization: language)!
            return try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as! [String: String]
        }
        let format = try NSRegularExpression(pattern: "%(%|@|lld|llu|ld|lu|d|u|f|g)")
        func placeholders(_ string: String) -> [String] {
            let text = string as NSString
            return format.matches(in: string, range: NSRange(location: 0, length: text.length)).map {
                text.substring(with: $0.range)
            }
        }
        for name in ["Localizable", "InfoPlist"] {
            let english = try table("en", name)
            for language in ["zh-Hans", "ja"] {
                let translated = try table(language, name)
                check(Set(english.keys) == Set(translated.keys), "\(language) \(name) key coverage")
                for (key, value) in english {
                    let target = translated[key] ?? ""
                    check(!target.isEmpty, "empty \(language) translation: \(key)")
                    check(placeholders(value) == placeholders(target), "\(language) format mismatch: \(key)")
                }
            }
        }
    }
}
