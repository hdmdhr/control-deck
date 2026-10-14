import Foundation

enum AppResources {
    static let bundle: Bundle? = {
        if Bundle.main.bundleURL.pathExtension == "app" {
            // The distribution scripts keep SwiftPM resources in the standard
            // macOS location. SwiftPM 6.2's generated accessor searches the
            // .app root, then an absolute path on the machine that built it.
            guard let url = Bundle.main.resourceURL?.appendingPathComponent(
                "ControlDeck_ControlDeck.bundle",
                isDirectory: true
            ) else { return nil }
            return Bundle(url: url)
        }

        // Preserve `swift run` and direct execution from the build directory.
        // Never evaluate this fatal-erroring accessor inside a packaged app:
        // a missing resource bundle should reach the caller's existing fallback.
        #if SWIFT_PACKAGE
        return Bundle.module
        #else
        return Bundle.main
        #endif
    }()

    static var localizationBundle: Bundle { bundle ?? .main }
}
