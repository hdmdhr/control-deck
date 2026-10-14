import AppKit
import SwiftUI

enum PS5Palette {
    static let canvas = Color(red: 0.965, green: 0.968, blue: 0.972)
    static let heroBlue = Color(red: 0.61, green: 0.78, blue: 0.96)
    static let acid = Color(red: 0.91, green: 1.0, blue: 0.08)
    static let border = Color.black.opacity(0.08)
    static let idle = Color(red: 0.25, green: 0.50, blue: 0.94)
    static let thinking = Color(red: 0.54, green: 0.43, blue: 0.90)
    static let complete = Color(red: 0.34, green: 0.68, blue: 0.38)
    static let needsInput = Color(red: 0.96, green: 0.73, blue: 0.16)
    static let error = Color(red: 0.89, green: 0.30, blue: 0.48)
}

struct ProjectRasterImage: View {
    let name: String

    static func load(_ name: String) -> NSImage? {
        guard let url = AppResources.bundle?.url(
            forResource: name,
            withExtension: "png"
        ) else { return nil }
        return NSImage(contentsOf: url)
    }

    @ViewBuilder
    var body: some View {
        if let image = Self.load(name) {
            Image(nsImage: image)
                .resizable()
        } else {
            Color.clear
        }
    }
}
