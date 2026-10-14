import AppKit
import SwiftUI

struct ControllerOverlayTask {
    let title: String
    let state: CodexTaskState
}

struct ProfileWheelEntry: Identifiable {
    let slot: ProfileWheelSlot
    let profile: ControllerProfile

    var id: Int { slot.position }
}

@MainActor
final class ControllerOverlayController {
    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?

    func showProfileWheel(
        profiles: [ControllerProfile],
        slots: [ProfileWheelSlot],
        activeKind: ProfileKind,
        selectedIndex: Int? = nil
    ) {
        hideWorkItem?.cancel()
        let entries = slots.compactMap { slot in
            profiles.first(where: { $0.kind == slot.profileKind }).map {
                ProfileWheelEntry(slot: slot, profile: $0)
            }
        }
        let view = ProfileWheelOverlay(
            entries: entries,
            activeKind: activeKind,
            selectedIndex: selectedIndex
        )
        show(
            AnyView(view),
            size: NSSize(width: 760, height: 760)
        )
    }

    func showReasoning(
        profile: ControllerProfile,
        task: ControllerOverlayTask?,
        step: ReasoningStep? = nil
    ) {
        hideWorkItem?.cancel()
        let view = ReasoningControllerOverlay(
            profileName: profile.displayName,
            task: task,
            step: step
        )
        show(
            AnyView(view),
            size: NSSize(width: 460, height: 250)
        )
    }

    func showContext(
        profile: ControllerProfile,
        task: ControllerOverlayTask?,
        profiles: [ControllerProfile],
        slots: [ProfileWheelSlot]
    ) {
        hideWorkItem?.cancel()
        let view = ContextControllerOverlay(
            profile: profile,
            task: task,
            profiles: profiles,
            slots: slots
        )
        show(
            AnyView(view),
            size: NSSize(width: 590, height: 495)
        )
        scheduleHide(after: 4)
    }

    func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    private func show(_ view: AnyView, size: NSSize) {
        let panel = panel ?? makePanel()
        self.panel = panel
        let animateEntrance = !panel.isVisible || panel.alphaValue < 0.05
        panel.setContentSize(size)
        panel.contentView = NSHostingView(rootView: view)
        if animateEntrance { position(panel) }
        guard animateEntrance else {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            return
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            panel.animator().alphaValue = 1
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 680),
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
        return panel
    }

    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: {
            NSMouseInRect(mouse, $0.frame, false)
        }) ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        panel.setFrameOrigin(
            NSPoint(
                x: visible.midX - panel.frame.width / 2,
                y: visible.midY - panel.frame.height / 2
            )
        )
    }

    private func scheduleHide(after delay: TimeInterval) {
        let item = DispatchWorkItem { [weak self] in self?.hide() }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
}

private struct OverlaySurface<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(24)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(.white.opacity(0.34), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.22), radius: 32, y: 16)
            .padding(26)
    }
}

private struct ProfileWheelOverlay: View {
    let entries: [ProfileWheelEntry]
    let activeKind: ProfileKind
    let selectedIndex: Int?

    private let wheelSize: CGFloat = 550

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: wheelSize + 48, height: wheelSize + 48)
                    .overlay {
                        Circle().stroke(.white.opacity(0.2), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.38), radius: 38, y: 18)

                wheel
                centerHub
                selectedTitle
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var wheel: some View {
        ZStack {
            ForEach(entries) { entry in
                let selected = selectedIndex == entry.slot.position
                let angle = angle(for: entry.slot.position)

                AnnularSector(
                    startDegrees: angle - 20.5,
                    endDegrees: angle + 20.5,
                    innerRatio: 0.39,
                    outerRatio: selected ? 0.99 : 0.92
                )
                .fill(
                    selected
                        ? Color(red: 0.06, green: 0.67, blue: 0.94)
                        : Color(red: 0.08, green: 0.12, blue: 0.15)
                            .opacity(0.9)
                )
                .overlay {
                    AnnularSector(
                        startDegrees: angle - 20.5,
                        endDegrees: angle + 20.5,
                        innerRatio: 0.39,
                        outerRatio: selected ? 0.99 : 0.92
                    )
                    .stroke(
                        selected
                            ? Color(red: 1, green: 0.74, blue: 0.2)
                            : .white.opacity(0.18),
                        lineWidth: selected ? 6 : 1.5
                    )
                }
                .offset(radialOffset(angle: angle, distance: selected ? 10 : 0))
                .animation(.spring(response: 0.18, dampingFraction: 0.78), value: selected)

                wheelLabel(entry, selected: selected)
                    .offset(radialOffset(angle: angle, distance: 185 + (selected ? 13 : 0)))
                    .animation(.spring(response: 0.18, dampingFraction: 0.78), value: selected)
            }
        }
        .frame(width: wheelSize, height: wheelSize)
    }

    private var centerHub: some View {
        VStack(spacing: 9) {
            Image(systemName: "l.joystick.tilt.up")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
            Text("PROFILE WHEEL")
                .font(.caption2.weight(.bold))
                .tracking(1.7)
                .foregroundStyle(.white.opacity(0.78))
            Text("Left stick")
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.58))
        }
        .frame(width: 190, height: 190)
        .background(
            Color(red: 0.035, green: 0.055, blue: 0.07).opacity(0.94),
            in: Circle()
        )
        .overlay {
            Circle().stroke(.white.opacity(0.18), lineWidth: 1.5)
        }
    }

    private var selectedTitle: some View {
        VStack(spacing: 5) {
            Text(selectedEntry?.profile.displayName ?? String(localized: "Choose a profile", bundle: AppResources.localizationBundle))
                .font(.system(size: 25, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 5, y: 2)
            Text(
                selectedEntry == nil
                    ? String(localized: "Move the left stick", bundle: AppResources.localizationBundle)
                    : String(localized: "Release Options to switch", bundle: AppResources.localizationBundle)
            )
            .font(.callout.weight(.medium))
            .foregroundStyle(.white.opacity(0.76))
        }
        .offset(y: 331)
    }

    private func wheelLabel(
        _ entry: ProfileWheelEntry,
        selected: Bool
    ) -> some View {
        VStack(spacing: 6) {
            ProfileLogoView(profile: entry.profile, size: selected ? 56 : 49)
                .shadow(color: .black.opacity(0.45), radius: 5, y: 2)
            HStack(spacing: 4) {
                Text(entry.profile.displayName)
                if entry.profile.kind == activeKind {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                }
            }
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: 92)
        }
    }

    private var selectedEntry: ProfileWheelEntry? {
        guard let selectedIndex else { return nil }
        return entries.first(where: { $0.slot.position == selectedIndex })
    }

    private func angle(for position: Int) -> Double {
        -90 + (Double(position) * 45)
    }

    private func radialOffset(
        angle: Double,
        distance: CGFloat
    ) -> CGSize {
        let radians = angle * .pi / 180
        return CGSize(
            width: cos(radians) * distance,
            height: sin(radians) * distance
        )
    }
}

private struct AnnularSector: Shape {
    let startDegrees: Double
    let endDegrees: Double
    let innerRatio: CGFloat
    let outerRatio: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let innerRadius = radius * innerRatio
        let outerRadius = radius * outerRatio
        let steps = 24
        var path = Path()

        for step in 0...steps {
            let progress = Double(step) / Double(steps)
            let degrees = startDegrees + ((endDegrees - startDegrees) * progress)
            let point = polarPoint(center, radius: outerRadius, degrees: degrees)
            step == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        for step in stride(from: steps, through: 0, by: -1) {
            let progress = Double(step) / Double(steps)
            let degrees = startDegrees + ((endDegrees - startDegrees) * progress)
            path.addLine(to: polarPoint(center, radius: innerRadius, degrees: degrees))
        }
        path.closeSubpath()
        return path
    }

    private func polarPoint(
        _ center: CGPoint,
        radius: CGFloat,
        degrees: Double
    ) -> CGPoint {
        let radians = degrees * .pi / 180
        return CGPoint(
            x: center.x + (cos(radians) * radius),
            y: center.y + (sin(radians) * radius)
        )
    }
}

private struct ReasoningControllerOverlay: View {
    let profileName: String
    let task: ControllerOverlayTask?
    let step: ReasoningStep?

    var body: some View {
        OverlaySurface {
            VStack(spacing: 15) {
                HStack {
                    Label("Reasoning effort", systemImage: "dial.medium")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Text("CREATE + R STICK")
                        .font(.caption2.weight(.bold))
                        .tracking(1)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 16) {
                    choice(String(localized: "Faster", bundle: AppResources.localizationBundle), icon: "chevron.down", active: step == .faster)
                    choice(String(localized: "Smarter", bundle: AppResources.localizationBundle), icon: "chevron.up", active: step == .smarter)
                }
                HStack {
                    Text(profileName)
                    Spacer()
                    if let task {
                        Text(task.title).lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func choice(
        _ title: String,
        icon: String,
        active: Bool
    ) -> some View {
        Label(title, systemImage: icon)
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(
                active ? Color.accentColor : Color.white.opacity(0.58),
                in: RoundedRectangle(cornerRadius: 15, style: .continuous)
            )
            .foregroundStyle(active ? .black : .primary)
    }
}

private struct ContextControllerOverlay: View {
    let profile: ControllerProfile
    let task: ControllerOverlayTask?
    let profiles: [ControllerProfile]
    let slots: [ProfileWheelSlot]

    var body: some View {
        OverlaySurface {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 13) {
                    ProfileLogoView(profile: profile, size: 36)
                        .frame(width: 44, height: 44)
                        .background(
                            Color.accentColor.opacity(0.16),
                            in: RoundedRectangle(
                                cornerRadius: 12,
                                style: .continuous
                            )
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.displayName)
                            .font(.title3.weight(.semibold))
                        Text("Current controller profile")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let task {
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(task.title).lineLimit(1)
                            Label(
                                task.state.label,
                                systemImage: "circle.fill"
                            )
                            .foregroundStyle(Color(nsColor: task.state.color))
                        }
                        .font(.caption)
                        .frame(maxWidth: 190, alignment: .trailing)
                    }
                }

                Divider()
                Text("PRIMARY CONTROLS")
                    .font(.caption2.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                LazyVGrid(
                    columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible())
                    ],
                    spacing: 8
                ) {
                    mapping(.cross)
                    mapping(.circle)
                    mapping(.l1)
                    mapping(.r1)
                    mapping(.l2)
                    mapping(.r2)
                }
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Hold Options")
                            .font(.headline)
                        Text("Choose one of eight profiles with the left stick")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        ForEach(slots) { slot in
                            if let wheelProfile = profiles.first(where: {
                                $0.kind == slot.profileKind
                            }) {
                                ProfileLogoView(
                                    profile: wheelProfile,
                                    size: 28
                                )
                            }
                        }
                    }
                }
                Text("Hold Create + move the right stick to adjust reasoning")
                    .font(.caption.weight(.medium))
                Text("Hold touchpad · right stick or D-pad to move · release to select")
                    .font(.caption.weight(.medium))
            }
        }
    }

    private func mapping(_ input: ControllerInput) -> some View {
        HStack(spacing: 9) {
            Text(input.shortLabel)
                .font(.caption.weight(.bold))
                .frame(width: 36, height: 28)
                .background(
                    .white.opacity(0.68),
                    in: RoundedRectangle(cornerRadius: 8)
                )
            Text(profile.action(for: input).label)
                .font(.caption)
                .lineLimit(1)
            Spacer()
        }
    }
}
