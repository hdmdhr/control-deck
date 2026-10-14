import AppKit
import Foundation

@main
struct ProfileApplicationActivationTests {
    @MainActor
    static func main() {
        let main = URL(fileURLWithPath: "/Applications/Main.app")
        let alias = URL(fileURLWithPath: "/Applications/Alias.app")
        let helper = URL(fileURLWithPath: "/Applications/Main.app/Contents/Frameworks/Helper.app")
        func expect(_ condition: Bool, _ message: String) {
            guard condition else { fatalError(message) }
        }
        expect(ProfileApplicationActivator.preferredApplicationURL(
            identifiers: ["example.main", "example.alias"],
            installedURL: { $0 == "example.main" ? main : nil },
            runningApplications: [("example.alias", alias, true)]
        ) == main, "installed primary app wins over running compatibility alias")
        expect(ProfileApplicationActivator.preferredApplicationURL(
            identifiers: ["example.*"], installedURL: { _ in nil },
            runningApplications: [("example.helper", helper, false), ("example.main", main, true)]
        ) == main, "wildcard ignores background helpers")
        expect(ProfileApplicationActivator.preferredApplicationURL(
            identifiers: ["example.*"], installedURL: { _ in nil },
            runningApplications: [("example.helper", helper, false)]
        ) == nil, "helper alone is unavailable")
        expect(ProfileApplicationActivator.preferredApplicationURL(
            identifiers: ["example.main"], installedURL: { _ in nil },
            runningApplications: [("example.main", main, true)]
        ) == main, "running bundle URL works without Launch Services registration")
        expect(ProfileApplicationActivator.preferredApplicationURL(
            identifiers: ["com.openai.codex", "com.ianhansel.controldeck"],
            installedURL: { $0 == "com.ianhansel.controldeck" ? alias : nil },
            runningApplications: [("com.ianhansel.controldeck", alias, true)]
        ) == nil, "ControlDeck never substitutes for an unavailable Codex application")
        print("PASS: application activation destination routing")
    }
}
