import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum ScreenshotEditorTool: String, Codable, CaseIterable, Identifiable,
    Sendable {
    case highlighter
    case pen
    case arrow
    case rectangle
    case text
    case redact

    var id: String { rawValue }

    var label: String {
        switch self {
        case .highlighter: String(localized: "Highlight", bundle: AppResources.localizationBundle)
        case .pen: String(localized: "Pen", bundle: AppResources.localizationBundle)
        case .arrow: String(localized: "Arrow", bundle: AppResources.localizationBundle)
        case .rectangle: String(localized: "Rectangle", bundle: AppResources.localizationBundle)
        case .text: String(localized: "Text", bundle: AppResources.localizationBundle)
        case .redact: String(localized: "Redact", bundle: AppResources.localizationBundle)
        }
    }

    var systemImage: String {
        switch self {
        case .highlighter: "highlighter"
        case .pen: "pencil.tip"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .text: "textformat"
        case .redact: "rectangle.fill"
        }
    }
}

enum ScreenshotAnnotationColor: String, Codable, CaseIterable, Identifiable,
    Sendable {
    case yellow
    case red
    case blue
    case green
    case white
    case black

    var id: String { rawValue }

    var label: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .yellow: .yellow
        case .red: .red
        case .blue: .blue
        case .green: .green
        case .white: .white
        case .black: .black
        }
    }
}

enum ScreenshotStrokeSize: String, Codable, CaseIterable, Identifiable,
    Sendable {
    case fine
    case medium
    case bold

    var id: String { rawValue }

    var label: String { rawValue.capitalized }

    var normalizedWidth: CGFloat {
        switch self {
        case .fine: 0.003
        case .medium: 0.006
        case .bold: 0.011
        }
    }
}

@MainActor
final class ScreenCapturePreferences: ObservableObject {
    @Published var copyOriginalToClipboard: Bool {
        didSet { defaults.set(copyOriginalToClipboard, forKey: Keys.copyOriginal) }
    }
    @Published var openEditorAfterCapture: Bool {
        didSet { defaults.set(openEditorAfterCapture, forKey: Keys.openEditor) }
    }
    @Published var copyEditedImageOnDone: Bool {
        didSet { defaults.set(copyEditedImageOnDone, forKey: Keys.copyEdited) }
    }
    @Published var editorStaysOnTop: Bool {
        didSet { defaults.set(editorStaysOnTop, forKey: Keys.staysOnTop) }
    }
    @Published var returnToPreviousApp: Bool {
        didSet { defaults.set(returnToPreviousApp, forKey: Keys.returnToApp) }
    }
    @Published var defaultTool: ScreenshotEditorTool {
        didSet { defaults.set(defaultTool.rawValue, forKey: Keys.tool) }
    }
    @Published var defaultColor: ScreenshotAnnotationColor {
        didSet { defaults.set(defaultColor.rawValue, forKey: Keys.color) }
    }
    @Published var defaultStrokeSize: ScreenshotStrokeSize {
        didSet { defaults.set(defaultStrokeSize.rawValue, forKey: Keys.stroke) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        copyOriginalToClipboard = defaults.object(forKey: Keys.copyOriginal)
            as? Bool ?? true
        openEditorAfterCapture = defaults.object(forKey: Keys.openEditor)
            as? Bool ?? true
        copyEditedImageOnDone = defaults.object(forKey: Keys.copyEdited)
            as? Bool ?? true
        editorStaysOnTop = defaults.object(forKey: Keys.staysOnTop)
            as? Bool ?? false
        returnToPreviousApp = defaults.object(forKey: Keys.returnToApp)
            as? Bool ?? true
        defaultTool = ScreenshotEditorTool(
            rawValue: defaults.string(forKey: Keys.tool) ?? ""
        ) ?? .highlighter
        defaultColor = ScreenshotAnnotationColor(
            rawValue: defaults.string(forKey: Keys.color) ?? ""
        ) ?? .yellow
        defaultStrokeSize = ScreenshotStrokeSize(
            rawValue: defaults.string(forKey: Keys.stroke) ?? ""
        ) ?? .medium
    }

    func reset() {
        copyOriginalToClipboard = true
        openEditorAfterCapture = true
        copyEditedImageOnDone = true
        editorStaysOnTop = false
        returnToPreviousApp = true
        defaultTool = .highlighter
        defaultColor = .yellow
        defaultStrokeSize = .medium
    }

    private enum Keys {
        static let copyOriginal = "screenCapture.copyOriginal.v1"
        static let openEditor = "screenCapture.openEditor.v1"
        static let copyEdited = "screenCapture.copyEdited.v1"
        static let staysOnTop = "screenCapture.staysOnTop.v1"
        static let returnToApp = "screenCapture.returnToApp.v1"
        static let tool = "screenCapture.defaultTool.v1"
        static let color = "screenCapture.defaultColor.v1"
        static let stroke = "screenCapture.defaultStroke.v1"
    }
}

struct ScreenshotAnnotation: Identifiable, Equatable {
    let id: UUID
    var tool: ScreenshotEditorTool
    var color: ScreenshotAnnotationColor
    var width: CGFloat
    var points: [CGPoint]
    var text: String

    init(
        id: UUID = UUID(),
        tool: ScreenshotEditorTool,
        color: ScreenshotAnnotationColor,
        width: CGFloat,
        points: [CGPoint],
        text: String = ""
    ) {
        self.id = id
        self.tool = tool
        self.color = color
        self.width = width
        self.points = points
        self.text = text
    }
}

enum ScreenshotCanvasGeometry {
    static func aspectFit(imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              bounds.width > 0, bounds.height > 0
        else { return .zero }
        let scale = min(
            bounds.width / imageSize.width,
            bounds.height / imageSize.height
        )
        let size = CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}

@MainActor
final class ScreenshotEditorModel: ObservableObject {
    let sourceImage: NSImage
    let originalOnClipboard: Bool
    @Published var tool: ScreenshotEditorTool
    @Published var color: ScreenshotAnnotationColor
    @Published var strokeSize: ScreenshotStrokeSize
    @Published var text = "Note"
    @Published private(set) var annotations: [ScreenshotAnnotation] = []
    @Published private(set) var draft: ScreenshotAnnotation?
    @Published private(set) var redoAnnotations: [ScreenshotAnnotation] = []
    @Published private(set) var status = String(localized: "Original copied to clipboard", bundle: AppResources.localizationBundle)

    init(image: NSImage, preferences: ScreenCapturePreferences) {
        sourceImage = image
        originalOnClipboard = preferences.copyOriginalToClipboard
        tool = preferences.defaultTool
        color = preferences.defaultColor
        strokeSize = preferences.defaultStrokeSize
        status = originalOnClipboard
            ? String(localized: "Original copied to clipboard", bundle: AppResources.localizationBundle)
            : String(localized: "Capture ready to edit", bundle: AppResources.localizationBundle)
    }

    var canUndo: Bool { !annotations.isEmpty }
    var canRedo: Bool { !redoAnnotations.isEmpty }

    func begin(at point: CGPoint) {
        let normalized = Self.clamped(point)
        draft = ScreenshotAnnotation(
            tool: tool,
            color: color,
            width: strokeSize.normalizedWidth,
            points: [normalized],
            text: tool == .text ? text : ""
        )
    }

    func update(to point: CGPoint) {
        guard var draft else { return }
        let normalized = Self.clamped(point)
        switch draft.tool {
        case .highlighter, .pen:
            draft.points.append(normalized)
        case .arrow, .rectangle, .redact:
            if draft.points.count == 1 {
                draft.points.append(normalized)
            } else {
                draft.points[draft.points.count - 1] = normalized
            }
        case .text:
            draft.points = [normalized]
        }
        self.draft = draft
    }

    func finish(at point: CGPoint) {
        update(to: point)
        guard let draft else { return }
        let isValid: Bool
        switch draft.tool {
        case .text:
            isValid = !draft.text.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
        default:
            isValid = draft.points.count >= 2
        }
        if isValid {
            annotations.append(draft)
            redoAnnotations.removeAll()
            status = String(localized: "Added \(draft.tool.label.lowercased())", bundle: AppResources.localizationBundle)
        }
        self.draft = nil
    }

    func cancelDraft() {
        draft = nil
    }

    func undo() {
        guard let annotation = annotations.popLast() else { return }
        redoAnnotations.append(annotation)
        status = String(localized: "Undid \(annotation.tool.label.lowercased())", bundle: AppResources.localizationBundle)
    }

    func redo() {
        guard let annotation = redoAnnotations.popLast() else { return }
        annotations.append(annotation)
        status = String(localized: "Redid \(annotation.tool.label.lowercased())", bundle: AppResources.localizationBundle)
    }

    func clear() {
        guard !annotations.isEmpty else { return }
        redoAnnotations.append(contentsOf: annotations.reversed())
        annotations.removeAll()
        status = String(localized: "Cleared annotations", bundle: AppResources.localizationBundle)
    }

    func selectAdjacentTool(offset: Int) {
        let tools = ScreenshotEditorTool.allCases
        guard let current = tools.firstIndex(of: tool) else { return }
        tool = tools[(current + offset + tools.count) % tools.count]
        status = String(localized: "\(tool.label) selected", bundle: AppResources.localizationBundle)
    }

    func renderedImage() -> NSImage? {
        let pixelSize = sourceImage.pixelSize
        guard pixelSize.width > 0, pixelSize.height > 0 else { return nil }
        let content = ScreenshotCompositeView(
            image: sourceImage,
            annotations: annotations
        )
        .frame(width: pixelSize.width, height: pixelSize.height)
        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(pixelSize)
        renderer.scale = 1
        return renderer.nsImage
    }

    @discardableResult
    func copyRenderedImage() -> Bool {
        guard let image = renderedImage() else {
            status = String(localized: "Could not render the edited image", bundle: AppResources.localizationBundle)
            return false
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let copied = pasteboard.writeObjects([image])
        status = copied ? String(localized: "Edited image copied", bundle: AppResources.localizationBundle) : String(localized: "Could not copy image", bundle: AppResources.localizationBundle)
        return copied
    }

    @discardableResult
    func saveRenderedImage() -> Bool {
        guard let image = renderedImage(),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            status = String(localized: "Could not render the edited image", bundle: AppResources.localizationBundle)
            return false
        }
        let panel = NSSavePanel()
        panel.title = String(localized: "Save Edited Screen Capture", bundle: AppResources.localizationBundle)
        panel.nameFieldStringValue = "ControlDeck Capture.png"
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let url = panel.url else {
            status = String(localized: "Save cancelled", bundle: AppResources.localizationBundle)
            return false
        }
        do {
            try png.write(to: url, options: .atomic)
            status = String(localized: "Saved \(url.lastPathComponent)", bundle: AppResources.localizationBundle)
            return true
        } catch {
            status = String(localized: "Could not save: \(error.localizedDescription)", bundle: AppResources.localizationBundle)
            return false
        }
    }

    private static func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(1, max(0, point.x)),
            y: min(1, max(0, point.y))
        )
    }
}

private extension NSImage {
    var pixelSize: CGSize {
        guard let representation = representations.max(by: {
            ($0.pixelsWide * $0.pixelsHigh) <
                ($1.pixelsWide * $1.pixelsHigh)
        }), representation.pixelsWide > 0, representation.pixelsHigh > 0
        else { return size }
        return CGSize(
            width: representation.pixelsWide,
            height: representation.pixelsHigh
        )
    }
}
