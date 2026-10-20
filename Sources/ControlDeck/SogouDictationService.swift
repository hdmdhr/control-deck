import AppKit
import ApplicationServices
import OSLog

/// Delegate recognition to the installed assistant. Never synthesize Option or
/// extract its service credentials. The 1.0.12 CLI forwards --from=hotkey to
/// the existing instance and toggles its free-speech session.
@MainActor
final class SogouDictationService {
    enum Presentation { case idle, recording, error, unavailable }
    enum Phase { case idle, starting, recording, stopping }
    private(set) var phase: Phase = .idle
    var isActive: Bool { phase != .idle }
    var onFinished: ((Bool) -> Void)?
    var onListening: (() -> Void)?
    private var held = false
    private var appURL: URL?
    private let launch: @MainActor (URL) async throws -> Void
    private let inspect: @MainActor () -> Presentation
    private let pause: @MainActor () async throws -> Void
    private let resolve: @MainActor () -> URL?
    private static var accessibilityPID: pid_t?
    private let logger = Logger(subsystem: "com.controldeck.app", category: "SogouDictation")
    static let bundleID = "com.sogou.voiceassistant"

    init(resolve: @escaping @MainActor () -> URL? = SogouDictationService.installedApp,
         launch: @escaping @MainActor (URL) async throws -> Void = SogouDictationService.toggle,
         inspect: @escaping @MainActor () -> Presentation = SogouDictationService.presentation,
         pause: @escaping @MainActor () async throws -> Void = { try await Task.sleep(nanoseconds: 100_000_000) }) {
        self.resolve = resolve; self.launch = launch; self.inspect = inspect; self.pause = pause
    }

    func begin() -> Bool {
        guard phase == .idle, let url = resolve(), inspect() == .idle else { return false }
        held = true; phase = .starting; appURL = url
        Task {
            do { try await launch(url) }
            catch { logger.error("Sogou launch reported an error; checking actual session state") }
            do {
                for _ in 0..<50 {
                    switch inspect() {
                    case .recording:
                        phase = .recording
                        logger.notice("Sogou session started")
                        if held { onListening?() } else { stop() }
                        return
                    case .error: finish(false); return
                    case .idle, .unavailable: try await pause()
                    }
                }
            } catch { logger.error("Sogou launch or readiness failed") }
            finish(false)
        }
        return true
    }

    func stop() {
        held = false
        guard phase == .recording, let url = appURL else { return }
        // A second CLI call is a toggle, not an idempotent stop. Never send it
        // if the user already ended the session or the assistant reports error.
        guard inspect() == .recording else { finish(false); return }
        phase = .stopping
        Task {
            do { try await launch(url) }
            catch { logger.error("Sogou stop request reported an error; checking actual session state") }
            do {
                for _ in 0..<50 {
                    if inspect() == .idle { finish(true); return }
                    if inspect() == .error { finish(false); return }
                    try await pause()
                }
            } catch { logger.error("Sogou stop failed") }
            finish(false)
        }
    }

    private func finish(_ succeeded: Bool) {
        phase = .idle; held = false; appURL = nil
        logger.notice("Sogou session finished, verified=\(succeeded, privacy: .public)")
        onFinished?(succeeded)
    }

    static func installedApp() -> URL? {
        let fallback = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/Sogou/SpeechAssistant/sogou_voice_assistant.app")
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) ?? fallback
        guard let bundle = Bundle(url: url), bundle.bundleIdentifier == bundleID,
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == "1.0.12" else { return nil }
        return url
    }

    private static func toggle(_ url: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--from=hotkey"]
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    func stopBeforeExit() {
        held = false
        guard isActive, let appURL, inspect() == .recording,
              let executable = Bundle(url: appURL)?.executableURL else { return }
        // Launch the same single-instance CLI synchronously before ControlDeck
        // exits; an async Task may otherwise never get scheduled at shutdown.
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--from=hotkey"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    /// Only inspect the assistant's own visible recording bubble. Read neither
    /// transcripts nor target-app content. Hidden pre-created windows are idle.
    static func presentation() -> Presentation {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return .idle }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        if accessibilityPID != app.processIdentifier {
            _ = AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            accessibilityPID = app.processIdentifier
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return .unavailable }
        let visible = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier }
        func attribute(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
            var v: CFTypeRef?
            return AXUIElementCopyAttributeValue(node, name as CFString, &v) == .success ? v : nil
        }
        for window in windows where attribute(window, kAXTitleAttribute) as? String == "搜狗语音输入法-输入气泡" {
            guard let p = attribute(window, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
                  let s = attribute(window, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return .unavailable }
            var point = CGPoint.zero; var size = CGSize.zero
            AXValueGetValue(p as! AXValue, .cgPoint, &point); AXValueGetValue(s as! AXValue, .cgSize, &size)
            let frame = CGRect(origin: point, size: size)
            guard visible.contains(where: { item in
                guard let bounds = item[kCGWindowBounds as String] as? [String: Any],
                      let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
                return abs(rect.midX - frame.midX) < 2 && abs(rect.midY - frame.midY) < 2
            }) else { continue }
            var queue = [window]; var visited = 0
            while !queue.isEmpty && visited < 300 {
                let node = queue.removeFirst(); visited += 1
                let classes = attribute(node, "AXDOMClassList") as? [String] ?? []
                if classes.contains(where: { $0.hasPrefix("index-module__startError___") }) { return .error }
                queue += attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
            }
            return .recording
        }
        return .idle
    }
}
