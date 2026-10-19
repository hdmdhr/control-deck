import ApplicationServices
import OSLog

/// Electron may expose only native window chrome until an assistive client
/// requests its Chromium tree. This flag uses the caller's existing AX access;
/// it does not change macOS privacy permissions or require VoiceOver.
enum ElectronAccessibility {
    private static let logger = Logger(subsystem: "com.controldeck.app", category: "ElectronAccessibility")

    @MainActor
    static func snapshot<Value>(application: AXUIElement, isFocused: () -> Bool,
                                read: () -> Value?) async -> Value? {
        guard !Task.isCancelled, isFocused() else { return nil }
        var enabled: CFTypeRef?
        let name = "AXManualAccessibility" as CFString
        if AXUIElementCopyAttributeValue(application, name, &enabled) != .success || (enabled as? Bool) != true {
            // Electron documents this attribute on the application element.
            // Do not require it to succeed: already exposed trees can still work.
            let result = AXUIElementSetAttributeValue(application, name, kCFBooleanTrue)
            logger.notice("Requested Electron AX tree, result=\(result.rawValue, privacy: .public)")
        }
        return await waitForSnapshot(isFocused: isFocused, read: read)
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
