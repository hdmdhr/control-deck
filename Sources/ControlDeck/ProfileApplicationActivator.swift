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

    /// Exact identifiers are ordered by the profile: the primary application
    /// must win over compatibility aliases, even when an alias is already open.
    static func preferredApplicationURL(
        identifiers: [String],
        installedURL: (String) -> URL?,
        runningApplications: [(identifier: String?, url: URL?, isRegular: Bool)]
    ) -> URL? {
        let identifiers = identifiers.filter {
            !["com.ianhansel.controldeck", "com.ianhansel.ps5codex"].contains($0)
        }
        for identifier in identifiers where !identifier.contains("*") {
            if let url = installedURL(identifier) { return url }
            if let running = runningApplications.first(where: {
                $0.isRegular && $0.identifier == identifier && $0.url != nil
            }) { return running.url }
        }
        // Wildcard assignments may target an already running GUI application,
        // but must never select an Electron/background helper process.
        for pattern in identifiers where pattern.hasSuffix("*") {
            let prefix = String(pattern.dropLast())
            if let running = runningApplications.first(where: {
                $0.isRegular && $0.identifier?.hasPrefix(prefix) == true && $0.url != nil
            }) { return running.url }
        }
        return nil
    }

    static func activate(_ profile: ControllerProfile) async -> Outcome {
        guard profile.kind != .general, !profile.bundleIdentifiers.isEmpty else {
            return .profileOnly
        }
        let workspace = NSWorkspace.shared
        let runningApplications = workspace.runningApplications.filter { !$0.isTerminated }
        guard let url = preferredApplicationURL(
            identifiers: profile.bundleIdentifiers,
            installedURL: { workspace.urlForApplication(withBundleIdentifier: $0) },
            runningApplications: runningApplications.map {
                ($0.bundleIdentifier, $0.bundleURL, $0.activationPolicy == .regular)
            }
        ) else { return .unavailable }

        if let running = runningApplications.first(where: {
            $0.activationPolicy == .regular && $0.bundleURL == url
        }) {
            if running.isActive { return .activationRequested(running.bundleIdentifier) }
            if running.isHidden { _ = running.unhide() }
            if NSApp.isActive { NSApp.yieldActivation(to: running) }
            if running.activate(options: [.activateAllWindows]) || running.isActive {
                return .activationRequested(running.bundleIdentifier)
            }
            // activate() can reject the direct request. Let Launch Services
            // reopen the main application instead of reporting failure early.
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
}
