import AppKit

/// Uses normal macOS application activation so window managers can follow their
/// configured focus rules without ControlDeck changing those rules.
@MainActor
enum ProfileApplicationActivator {
    enum Outcome {
        case profileOnly
        case activationRequested(String?)
        case unavailable
        case failed
    }

    static func activate(_ profile: ControllerProfile) async -> Outcome {
        guard profile.kind != .general, !profile.bundleIdentifiers.isEmpty else {
            return .profileOnly
        }
        let workspace = NSWorkspace.shared
        if let running = workspace.runningApplications.first(where: {
            !$0.isTerminated && profile.matches(
                bundleIdentifier: $0.bundleIdentifier,
                windowTitle: nil
            )
        }) {
            return running.activate(options: [.activateAllWindows])
                ? .activationRequested(running.bundleIdentifier) : .failed
        }
        // Launch Services requires an exact bundle identifier. Wildcard-only
        // assignments can still activate a matching running application above.
        for identifier in profile.bundleIdentifiers where !identifier.contains("*") {
            guard let url = workspace.urlForApplication(withBundleIdentifier: identifier) else {
                continue
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            do {
                let application = try await workspace.openApplication(at: url, configuration: configuration)
                return .activationRequested(application.bundleIdentifier)
            } catch {
                return .failed
            }
        }
        return .unavailable
    }
}
