import AppKit
import SwiftUI

enum ScreenshotEditorControllerAction {
    case tool(String)
    case undo
    case redo
    case copied
    case saved
    case dismissed
    case done
}

@MainActor
final class ScreenshotEditorController: NSObject, NSWindowDelegate {
    private let preferences: ScreenCapturePreferences
    var onDone: ((Bool) -> Void)?
    private var window: NSWindow?
    private(set) var model: ScreenshotEditorModel?
    private var previousApplication: NSRunningApplication?
    private var closingProgrammatically = false

    init(preferences: ScreenCapturePreferences) {
        self.preferences = preferences
    }

    var isPresented: Bool { window?.isVisible == true }

    func present(image: NSImage) {
        if isPresented { dismiss(restorePreviousApplication: false) }

        previousApplication = NSWorkspace.shared.frontmostApplication
        let model = ScreenshotEditorModel(
            image: image,
            preferences: preferences
        )
        self.model = model

        let root = ScreenshotEditorRootView(
            model: model,
            copyOnDone: preferences.copyEditedImageOnDone,
            onClose: { [weak self] in self?.dismiss() },
            onDone: { [weak self] in self?.done() },
            onCopy: { _ = model.copyRenderedImage() },
            onSave: { _ = model.saveRenderedImage() }
        )
        let hostingView = NSHostingView(rootView: root)
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_120, height: 760),
            styleMask: [
                .titled, .closable, .miniaturizable, .resizable
            ],
            backing: .buffered,
            defer: false
        )
        panel.title = String(localized: "Screen Capture Editor", bundle: AppResources.localizationBundle)
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = hostingView
        panel.minSize = NSSize(width: 760, height: 540)
        panel.level = preferences.editorStaysOnTop ? .floating : .normal
        panel.collectionBehavior = [.fullScreenAuxiliary]
        position(panel, image: image)
        window = panel

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func handleControllerButton(
        _ input: ControllerInput
    ) -> ScreenshotEditorControllerAction? {
        guard let model else { return nil }
        switch input {
        case .l1, .dpadLeft:
            model.selectAdjacentTool(offset: -1)
            return .tool(model.tool.label)
        case .r1, .dpadRight:
            model.selectAdjacentTool(offset: 1)
            return .tool(model.tool.label)
        case .square:
            model.undo()
            return .undo
        case .triangle:
            model.redo()
            return .redo
        case .circle:
            dismiss()
            return .dismissed
        case .options:
            done()
            return .done
        case .create:
            return model.saveRenderedImage() ? .saved : nil
        case .touchpadClick:
            return model.copyRenderedImage() ? .copied : nil
        default:
            return nil
        }
    }

    func done() {
        guard let model else { return }
        var copied = false
        if preferences.copyEditedImageOnDone {
            copied = model.copyRenderedImage()
        }
        onDone?(copied)
        dismiss()
    }

    func dismiss(restorePreviousApplication: Bool? = nil) {
        guard let window else { return }
        closingProgrammatically = true
        window.orderOut(nil)
        window.close()
        self.window = nil
        model = nil
        closingProgrammatically = false
        restorePreviousAppIfNeeded(
            restorePreviousApplication ?? preferences.returnToPreviousApp
        )
    }

    func windowWillClose(_ notification: Notification) {
        guard !closingProgrammatically else { return }
        window = nil
        model = nil
        restorePreviousAppIfNeeded(preferences.returnToPreviousApp)
    }

    private func position(_ window: NSWindow, image: NSImage) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: {
            NSMouseInRect(mouse, $0.frame, false)
        }) ?? NSScreen.main
        guard let visible = screen?.visibleFrame else {
            window.center()
            return
        }
        let aspect = max(0.65, min(1.8, image.size.width / image.size.height))
        let width = min(1_260, max(820, visible.width * 0.72))
        let height = min(
            visible.height * 0.82,
            max(600, (width / aspect) + 170)
        )
        window.setContentSize(NSSize(width: width, height: height))
        window.setFrameOrigin(
            NSPoint(
                x: visible.midX - window.frame.width / 2,
                y: visible.midY - window.frame.height / 2
            )
        )
    }

    private func restorePreviousAppIfNeeded(_ shouldRestore: Bool) {
        defer { previousApplication = nil }
        guard shouldRestore,
              let previousApplication,
              !previousApplication.isTerminated
        else { return }
        previousApplication.activate(options: [])
    }
}

private struct ScreenshotEditorRootView: View {
    @ObservedObject var model: ScreenshotEditorModel
    let copyOnDone: Bool
    let onClose: () -> Void
    let onDone: () -> Void
    let onCopy: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            toolStrip
            Divider()

            HStack(spacing: 0) {
                ScreenshotCanvasView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                inspector
                    .frame(width: 205)
            }

            Divider()
            controllerHints
        }
        .background(.regularMaterial)
        .frame(minWidth: 760, minHeight: 540)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Dismiss and keep the original clipboard image")

            VStack(alignment: .leading, spacing: 2) {
                Text("Screen Capture Editor")
                    .font(.headline)
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            Label(
                copyOnDone
                    ? String(localized: "Done copies the marked-up image", bundle: AppResources.localizationBundle)
                    : String(localized: "Done closes without copying", bundle: AppResources.localizationBundle),
                systemImage: copyOnDone ? "doc.on.clipboard.fill" : "xmark.circle"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(copyOnDone ? Color.green : Color.secondary)

            Button("Copy", systemImage: "doc.on.doc", action: onCopy)
                .keyboardShortcut("c", modifiers: .command)
            Button("Save", systemImage: "square.and.arrow.down", action: onSave)
                .keyboardShortcut("s", modifiers: .command)
            Button(
                copyOnDone ? String(localized: "Done & Copy", bundle: AppResources.localizationBundle) : String(localized: "Done", bundle: AppResources.localizationBundle),
                systemImage: copyOnDone ? "doc.on.clipboard.fill" : "checkmark",
                action: onDone
            )
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [.command])
                .help(
                    copyOnDone
                        ? String(localized: "Close the editor and copy the marked-up image to the clipboard", bundle: AppResources.localizationBundle)
                        : "Close the editor without changing the clipboard"
                )
        }
        .padding(.horizontal, 18)
        .padding(.top, 13)
        .padding(.bottom, 10)
    }

    private var toolStrip: some View {
        HStack(spacing: 7) {
            ForEach(ScreenshotEditorTool.allCases) { tool in
                Button {
                    model.tool = tool
                } label: {
                    Label(tool.label, systemImage: tool.systemImage)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 9)
                        .frame(height: 32)
                        .background(
                            model.tool == tool
                                ? Color.accentColor.opacity(0.18)
                                : Color.clear,
                            in: RoundedRectangle(
                                cornerRadius: 8,
                                style: .continuous
                            )
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Button("Undo", systemImage: "arrow.uturn.backward") {
                model.undo()
            }
            .disabled(!model.canUndo)
            .keyboardShortcut("z", modifiers: .command)
            Button("Redo", systemImage: "arrow.uturn.forward") {
                model.redo()
            }
            .disabled(!model.canRedo)
            .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("STYLE")
                .font(.caption2.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(.secondary)

            Text("Colour")
                .font(.caption.weight(.semibold))
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(34)), count: 3),
                spacing: 10
            ) {
                ForEach(ScreenshotAnnotationColor.allCases) { color in
                    Button {
                        model.color = color
                    } label: {
                        Circle()
                            .fill(color.color)
                            .frame(width: 27, height: 27)
                            .overlay {
                                Circle().stroke(
                                    model.color == color
                                        ? Color.accentColor
                                        : Color.primary.opacity(0.2),
                                    lineWidth: model.color == color ? 3 : 1
                                )
                            }
                    }
                    .buttonStyle(.plain)
                    .help(color.label)
                }
            }

            Picker("Size", selection: $model.strokeSize) {
                ForEach(ScreenshotStrokeSize.allCases) { size in
                    Text(size.label).tag(size)
                }
            }

            if model.tool == .text {
                TextField("Annotation text", text: $model.text)
            }

            Divider()
            Button("Clear all", systemImage: "trash", role: .destructive) {
                model.clear()
            }
            .disabled(!model.canUndo)

            Spacer()
            Text(
                copyOnDone
                    ? String(localized: "Done & Copy replaces the clipboard with the current image and all markup. It will be ready to paste immediately.", bundle: AppResources.localizationBundle)
                    : model.originalOnClipboard
                    ? String(localized: "The unedited capture was copied before this window opened. Dismiss at any time to keep it unchanged.", bundle: AppResources.localizationBundle)
                    : String(localized: "Dismiss without changing the clipboard, or choose Copy when the edit is ready.", bundle: AppResources.localizationBundle)
            )
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .background(.thinMaterial)
    }

    private var controllerHints: some View {
        HStack(spacing: 16) {
            hint(String(localized: "L STICK", bundle: AppResources.localizationBundle), String(localized: "Pointer", bundle: AppResources.localizationBundle))
            hint(String(localized: "CROSS", bundle: AppResources.localizationBundle), String(localized: "Draw", bundle: AppResources.localizationBundle))
            hint(String(localized: "L1 / R1", bundle: AppResources.localizationBundle), String(localized: "Tool", bundle: AppResources.localizationBundle))
            hint(String(localized: "SQUARE", bundle: AppResources.localizationBundle), String(localized: "Undo", bundle: AppResources.localizationBundle))
            hint(String(localized: "TRIANGLE", bundle: AppResources.localizationBundle), String(localized: "Redo", bundle: AppResources.localizationBundle))
            hint(String(localized: "CREATE", bundle: AppResources.localizationBundle), String(localized: "Save", bundle: AppResources.localizationBundle))
            hint(String(localized: "OPTIONS", bundle: AppResources.localizationBundle), String(localized: "Done", bundle: AppResources.localizationBundle))
            hint(String(localized: "CIRCLE", bundle: AppResources.localizationBundle), String(localized: "Dismiss", bundle: AppResources.localizationBundle))
            Spacer()
        }
        .padding(.horizontal, 18)
        .frame(height: 44)
        .background(.thinMaterial)
    }

    private func hint(_ control: String, _ action: String) -> some View {
        HStack(spacing: 5) {
            Text(control)
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            Text(action)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ScreenshotCanvasView: View {
    @ObservedObject var model: ScreenshotEditorModel
    @State private var drawing = false

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
                .insetBy(dx: 24, dy: 24)
            let imageRect = ScreenshotCanvasGeometry.aspectFit(
                imageSize: model.sourceImage.size,
                in: bounds
            )

            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                ScreenshotCompositeView(
                    image: model.sourceImage,
                    annotations: model.annotations + [model.draft].compactMap { $0 }
                )
                .frame(width: imageRect.width, height: imageRect.height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let point = normalized(
                                value.location,
                                size: imageRect.size
                            )
                            if !drawing {
                                drawing = true
                                model.begin(at: point)
                            } else {
                                model.update(to: point)
                            }
                        }
                        .onEnded { value in
                            model.finish(
                                at: normalized(
                                    value.location,
                                    size: imageRect.size
                                )
                            )
                            drawing = false
                        }
                )
                .position(x: imageRect.midX, y: imageRect.midY)
                .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
            }
        }
    }

    private func normalized(_ point: CGPoint, size: CGSize) -> CGPoint {
        guard size.width > 0, size.height > 0 else { return .zero }
        return CGPoint(x: point.x / size.width, y: point.y / size.height)
    }
}

struct ScreenshotCompositeView: View {
    let image: NSImage
    let annotations: [ScreenshotAnnotation]

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                Canvas { context, size in
                    for annotation in annotations {
                        draw(annotation, in: &context, size: size)
                    }
                }
            }
        }
    }

    private func draw(
        _ annotation: ScreenshotAnnotation,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        let points = annotation.points.map {
            CGPoint(x: $0.x * size.width, y: $0.y * size.height)
        }
        guard let first = points.first else { return }
        let baseWidth = annotation.width * min(size.width, size.height)

        switch annotation.tool {
        case .highlighter, .pen:
            guard points.count >= 2 else { return }
            var path = Path()
            path.addLines(points)
            var layer = context
            if annotation.tool == .highlighter {
                layer.opacity = 0.42
                layer.blendMode = .multiply
            }
            layer.stroke(
                path,
                with: .color(annotation.color.color),
                style: StrokeStyle(
                    lineWidth: annotation.tool == .highlighter
                        ? baseWidth * 4.2 : baseWidth,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
        case .arrow:
            guard let last = points.last, points.count >= 2 else { return }
            var path = Path()
            path.move(to: first)
            path.addLine(to: last)
            let angle = atan2(last.y - first.y, last.x - first.x)
            let head = max(12, baseWidth * 4)
            path.move(to: last)
            path.addLine(to: CGPoint(
                x: last.x - cos(angle - .pi / 6) * head,
                y: last.y - sin(angle - .pi / 6) * head
            ))
            path.move(to: last)
            path.addLine(to: CGPoint(
                x: last.x - cos(angle + .pi / 6) * head,
                y: last.y - sin(angle + .pi / 6) * head
            ))
            context.stroke(
                path,
                with: .color(annotation.color.color),
                style: StrokeStyle(lineWidth: baseWidth, lineCap: .round)
            )
        case .rectangle, .redact:
            guard let last = points.last, points.count >= 2 else { return }
            let rect = CGRect(
                x: min(first.x, last.x),
                y: min(first.y, last.y),
                width: abs(last.x - first.x),
                height: abs(last.y - first.y)
            )
            if annotation.tool == .redact {
                context.fill(Path(rect), with: .color(.black))
            } else {
                context.stroke(
                    Path(rect),
                    with: .color(annotation.color.color),
                    style: StrokeStyle(
                        lineWidth: baseWidth,
                        lineJoin: .round
                    )
                )
            }
        case .text:
            context.draw(
                Text(annotation.text)
                    .font(.system(
                        size: max(14, min(size.width, size.height) * 0.04),
                        weight: .bold
                    ))
                    .foregroundStyle(annotation.color.color),
                at: first,
                anchor: .topLeading
            )
        }
    }
}
