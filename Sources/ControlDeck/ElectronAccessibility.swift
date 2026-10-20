import AppKit
import ApplicationServices
import OSLog

/// Electron may expose only native window chrome until an assistive client
/// requests its Chromium tree. This flag uses the caller's existing AX access;
/// it does not change macOS privacy permissions or require VoiceOver.
enum ElectronAccessibility {
    enum Runtime { case electron, chromium }
    private struct Request {
        let application: AXUIElement
        let launchDate: Date?
    }
    @MainActor private static var requests: [Request] = []
    private static let logger = Logger(subsystem: "com.controldeck.app", category: "ElectronAccessibility")

    @MainActor
    static func snapshot<Value>(application: AXUIElement, runtime: Runtime = .electron, isFocused: () -> Bool,
                                read: () -> Value?) async -> Value? {
        guard !Task.isCancelled, isFocused() else { return nil }
        if let value = read() { return isFocused() ? value : nil }
        var pid: pid_t = 0
        AXUIElementGetPid(application, &pid)
        let launchDate = NSRunningApplication(processIdentifier: pid)?.launchDate
        if !requests.contains(where: { CFEqual($0.application, application) && $0.launchDate == launchDate }) {
            let name = runtime == .chromium ? "AXEnhancedUserInterface" : "AXManualAccessibility"
            let result = AXUIElementSetAttributeValue(application, name as CFString, kCFBooleanTrue)
            logger.notice("Requested browser AX tree via \(name, privacy: .public), result=\(result.rawValue, privacy: .public)")
            if result == .success {
                requests.append(Request(application: application, launchDate: launchDate))
            }
        }
        // Chromium debounces enhanced-UI requests for two seconds. Repeating
        // true on each keypress would keep restarting that timer indefinitely.
        return await waitForSnapshot(attempts: runtime == .chromium ? 35 : 8, isFocused: isFocused, read: read)
    }

    /// Rendering the tree is asynchronous. Bound the wait and recheck focus
    /// before every read and before returning a candidate to the navigator.
    @MainActor
    static func waitForSnapshot<Value>(attempts: Int = 8, isFocused: () -> Bool,
                                      read: () -> Value?,
                                      pause: () async throws -> Void = {
                                          try await Task.sleep(nanoseconds: 100_000_000)
                                      }) async -> Value? {
        for attempt in 0..<max(0, attempts) {
            guard !Task.isCancelled, isFocused() else { return nil }
            if let value = read() { return isFocused() ? value : nil }
            guard attempt + 1 < attempts else { break }
            do { try await pause() } catch { return nil }
        }
        return nil
    }
}
