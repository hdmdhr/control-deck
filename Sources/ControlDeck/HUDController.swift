import AppKit

@MainActor
final class HUDController {
    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?

    func show(_ message: String, detail: String? = nil, color: NSColor) {
        present(
            message,
            detail: detail,
            color: color,
            autoHideAfter: 1.45
        )
    }

    func showStreaming(
        _ message: String,
        detail: String? = nil,
        color: NSColor
    ) {
        present(
            message,
            detail: detail,
            color: color,
            autoHideAfter: nil
        )
    }

    func dismiss() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        panel?.orderOut(nil)
    }

    func updateInputLevel(_ level: Float) {
        guard let content = panel?.contentView,
              let meter = content.subviews.first(where: {
                  $0.identifier ==
                      NSUserInterfaceItemIdentifier("input-meter")
              }),
              let fill = meter.subviews.first
        else { return }
        let clamped = CGFloat(min(1, max(0, level)))
        fill.frame.size.width = meter.bounds.width * clamped
    }

    private func present(
        _ message: String,
        detail: String?,
        color: NSColor,
        autoHideAfter: TimeInterval?
    ) {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        let panel = panel ?? makePanel()
        self.panel = panel
        guard let content = panel.contentView,
              let title = content.viewWithTag(100) as? NSTextField,
              let subtitle = content.viewWithTag(101) as? NSTextField,
              let dot = content.subviews.first(where: {
                  $0.identifier == NSUserInterfaceItemIdentifier("state-dot")
              })
        else { return }

        title.stringValue = message
        subtitle.stringValue = detail ?? ""
        subtitle.isHidden = detail?.isEmpty != false
        dot.layer?.backgroundColor = color.cgColor
        position(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }

        guard let autoHideAfter else { return }
        let workItem = DispatchWorkItem { [weak self, weak panel] in
            guard let self, let panel else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.orderOut(nil)
            })
            self.hideWorkItem = nil
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + autoHideAfter,
            execute: workItem
        )
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 330, height: 86),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true

        let effect = NSVisualEffectView(frame: panel.contentView!.bounds)
        effect.autoresizingMask = [.width, .height]
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true

        let dot = NSView(frame: NSRect(x: 20, y: 33, width: 20, height: 20))
        dot.identifier = NSUserInterfaceItemIdentifier("state-dot")
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 10
        effect.addSubview(dot)

        let title = NSTextField(labelWithString: "")
        title.tag = 100
        title.frame = NSRect(x: 54, y: 46, width: 254, height: 22)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .labelColor
        effect.addSubview(title)

        let subtitle = NSTextField(labelWithString: "")
        subtitle.tag = 101
        subtitle.frame = NSRect(x: 54, y: 25, width: 254, height: 18)
        subtitle.font = .systemFont(ofSize: 11.5, weight: .medium)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        effect.addSubview(subtitle)

        let meter = NSView(
            frame: NSRect(x: 54, y: 14, width: 254, height: 4)
        )
        meter.identifier = NSUserInterfaceItemIdentifier("input-meter")
        meter.wantsLayer = true
        meter.layer?.backgroundColor =
            NSColor.secondaryLabelColor.withAlphaComponent(0.18).cgColor
        meter.layer?.cornerRadius = 2
        let fill = NSView(
            frame: NSRect(x: 0, y: 0, width: 0, height: 4)
        )
        fill.wantsLayer = true
        fill.layer?.backgroundColor = NSColor.systemGreen.cgColor
        fill.layer?.cornerRadius = 2
        meter.addSubview(fill)
        effect.addSubview(meter)

        panel.contentView = effect
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        panel.setFrameOrigin(
            NSPoint(
                x: visible.maxX - panel.frame.width - 22,
                y: visible.maxY - panel.frame.height - 22
            )
        )
    }
}
