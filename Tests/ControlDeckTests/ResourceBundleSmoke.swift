import AppKit
import Foundation

@main
struct ResourceBundleSmoke {
    static func main() {
        do {
            try run()
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func run() throws {
        if CommandLine.arguments.contains("--expect-missing") {
            try check(AppResources.bundle == nil, "missing bundle must return nil")
            try check(ProjectRasterImage.load("dualsense-hero") == nil,
                      "missing bundle must use image fallback")
            print("PASS: missing packaged resources do not trap")
            return
        }

        // Exercise the same image loader that previously crashed at launch.
        try check(ProjectRasterImage.load("dualsense-hero") != nil,
                  "hero image must decode (main bundle: \(Bundle.main.bundleURL))")
        try check(ProjectRasterImage.load("nonexistent-image") == nil,
                  "missing image must return nil")
        let bundle = try require(AppResources.bundle, "resource bundle")
        if Bundle.main.bundleURL.pathExtension == "app" {
            try check(bundle.bundleURL.deletingLastPathComponent().standardizedFileURL.path
                == Bundle.main.resourceURL?.standardizedFileURL.path,
                "packaged resources must come from Contents/Resources")
        }

        // Cover the other resource consumers, not just the first dashboard image.
        for (name, ext) in [
            ("control-deck-logo-horizontal", "png"),
            ("index", "html"),
            ("game.bundle", "js"),
            ("control_deck_mcp", "py"),
            ("SKILL", "md"),
            ("openai", "yaml")
        ] {
            let url = try require(
                bundle.url(forResource: name, withExtension: ext),
                "\(name).\(ext)"
            )
            let data = try Data(contentsOf: url)
            try check(!data.isEmpty, "\(name).\(ext) must not be empty")
        }
        print("PASS: images, Tilt Run and customization resources load")
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw NSError(domain: "ResourceBundleSmoke", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private static func require<T>(_ value: T?, _ name: String) throws -> T {
        guard let value else {
            throw NSError(
                domain: "ResourceBundleSmoke", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing \(name)"]
            )
        }
        return value
    }
}
