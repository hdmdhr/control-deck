import AppKit
import SwiftUI

struct ControllerMappingView: View {
    @Binding var selectedInput: ControllerInput
    let profile: ControllerProfile
    let availableProfiles: [ControllerProfile]
    let activeProfileName: String
    let selectProfile: (ProfileKind) -> Void
    let openPointerSettings: () -> Void
    let openTouchpadSettings: () -> Void
    let actionForInput: (ControllerInput) -> MappedAction
    let setAction: (MappedAction, ControllerInput) -> Void
    let resetSelected: () -> Void

    @State private var searchText = ""
    @State private var relevantOnly = true
    @State private var selectedCategory: ActionCategory?

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    mappingHeader
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            controllerCanvas.frame(height: 260)
                            movementSummary
                            Text("Buttons · press to assign")
                                .font(.headline)
                            LazyVStack(spacing: 3) {
                                ForEach(ControllerInput.allCases) { input in
                                    inputRow(input)
                                }
                            }
                            touchpadSummary
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                    }
                }
                .frame(maxWidth: .infinity)
                Divider()
                inspector
                    .frame(width: max(340, min(430, proxy.size.width * 0.38)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
        .onChange(of: profile.kind) { _, _ in selectedCategory = nil }
    }

    private var mappingHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Button Mapping").font(.system(size: 28, weight: .bold, design: .rounded))
            HStack(spacing: 10) {
                Text("Editing profile").font(.caption).foregroundStyle(.secondary)
                Picker("Editing profile", selection: Binding(get: { profile.kind }, set: selectProfile)) {
                    ForEach(availableProfiles) { item in
                        Text(item.displayName).tag(item.kind)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
                Spacer(minLength: 0)
            }
            Text(profileApplications)
                .font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Label("Active profile", systemImage: "bolt.circle")
                Text(activeProfileName).fontWeight(.medium)
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
    }

    private var profileApplications: String {
        if profile.kind == .codex {
            return localized("Codex / ChatGPT share one app and this profile.")
        }
        let apps = profile.bundleIdentifiers.compactMap { identifier -> String? in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else { return identifier }
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return localized("Associated apps") + ": " + (apps.isEmpty ? profile.kind.label : apps.joined(separator: ", "))
    }

    private var controllerCanvas: some View {
        GeometryReader { proxy in
            let baseWidth: CGFloat = 800
            let imageWidth = min(proxy.size.width, 580)
            let imageHeight = baseWidth / 1.5
            ZStack {
                ProjectRasterImage(name: "dualsense-turn-1").scaledToFit()
                    .accessibilityLabel("Tilted DualSense controller with selectable controls")
                ForEach(shoulderCallouts) { callout in
                    calloutLine(callout, imageWidth: baseWidth, imageHeight: imageHeight)
                }
                ForEach(mappingHotspots) { hotspot in
                    mappingButton(hotspot)
                        .position(x: baseWidth * hotspot.x, y: imageHeight * hotspot.y)
                }
                ForEach(shoulderCallouts) { callout in
                    calloutButton(callout, imageWidth: baseWidth, imageHeight: imageHeight)
                }
            }
            .frame(width: baseWidth, height: imageHeight)
            .scaleEffect(imageWidth / baseWidth, anchor: .top)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            .clipped()
        }
    }

    private var movementSummary: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Stick movement · separate from L3 / R3 presses").font(.headline)
            ForEach([ControllerStick.left, .right]) { stick in
                Button(action: openPointerSettings) {
                    HStack {
                        Label(stick.label, systemImage: "l.joystick")
                        Spacer()
                        Text(stickMovement(stick)).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.caption)
                    }
                    .font(.subheadline)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if profile.action(for: .r3) == .textSelectionHold && profile.pointer.caretSource == .right {
                Text("Hold R3 while moving the right stick to select text. Release R3 to keep the selection.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Caret movement takes priority over pointer movement, then scrolling.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func stickMovement(_ stick: ControllerStick) -> String {
        if profile.pointer.caretSource == stick { return localized("Text caret · tilt to repeat arrows") }
        if profile.pointer.source == stick { return localized("Pointer") }
        if profile.pointer.scrollSource == stick { return localized("Scroll") }
        return localized("Off")
    }

    private func inputRow(_ input: ControllerInput) -> some View {
        Button { selectedInput = input } label: {
            HStack(spacing: 10) {
                Text(controllerGlyph(input))
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 34)
                Text(input == .l3 ? localized("L3 · left stick press") : input == .r3 ? localized("R3 · right stick press") : input.label)
                    .font(.system(size: 13, weight: .medium))
                Spacer(minLength: 10)
                Text(actionForInput(input).label)
                    .font(.system(size: 12))
                    .foregroundStyle(actionForInput(input) == .none ? .secondary : .primary)
                    .multilineTextAlignment(.trailing)
                if selectedInput == input {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selectedInput == input ? Color.accentColor.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var touchpadSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Touchpad movement & gestures").font(.headline)
                Spacer()
                Button("Edit touchpad", action: openTouchpadSettings).font(.caption)
            }
            summaryRow(localized("One-finger movement"), value: profile.touchpad.oneFingerMode.label)
            summaryRow(localized("Two-finger movement"), value: localized(profile.touchpad.twoFingerScroll ? "Scroll" : "Gestures"))
            summaryRow(localized("Natural scrolling"), value: localized(profile.touchpad.naturalScrolling ? "On" : "Off"))
            Text("Touchpad click is a separate button in the list above.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(TouchGesture.allCases) { gesture in
                summaryRow(gesture.label, value: profile.touchpad.action(for: gesture).label)
            }
            Text("Swipes are available only when movement uses Gestures mode.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func summaryRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.caption)
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                controlBadge(selectedInput, selected: true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedInput == .l3 ? localized("L3 · left stick press") : selectedInput == .r3 ? localized("R3 · right stick press") : selectedInput.label)
                        .font(.title3.weight(.semibold))
                    Text(inputDescription(selectedInput)).font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Current action").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Unassign") { setAction(.none, selectedInput) }.font(.caption)
                }
                Label(actionForInput(selectedInput).label, systemImage: actionIcon(actionForInput(selectedInput)))
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

            Picker("Action scope", selection: $relevantOnly) {
                Text("This profile").tag(true)
                Text("All actions").tag(false)
            }
            .pickerStyle(.segmented)
            .onChange(of: relevantOnly) { _, _ in selectedCategory = nil }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search actions or apps", text: $searchText).textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel("Clear search")
                }
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            Picker("Category", selection: $selectedCategory) {
                Text("All categories").tag(nil as ActionCategory?)
                ForEach(catalogCategories) { category in
                    Text(category.label).tag(Optional(category))
                }
            }
            Text("Choose an action to assign it immediately.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if filteredCategories.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("No matching actions").font(.headline)
                            Text("Try another search or browse all actions.").foregroundStyle(.secondary)
                            Button("Show all actions") {
                                searchText = ""; relevantOnly = false; selectedCategory = nil
                            }
                        }
                        .font(.subheadline).padding(.vertical, 20)
                    }
                    ForEach(filteredCategories) { category in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(category.label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(filteredActions(in: category)) { action in actionRow(action) }
                        }
                    }
                }
            }
            Button(action: resetSelected) {
                Label("Reset selected button", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        }
        .padding(20)
    }

    private func localized(_ key: String) -> String {
        AppResources.localizationBundle.localizedString(forKey: key, value: key, table: nil)
    }

    private func actionRow(_ action: MappedAction) -> some View {
        Button {
            setAction(action, selectedInput)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: actionIcon(action))
                    .frame(width: 18)
                    .foregroundStyle(Color.accentColor)
                Text(actionDisplayName(action))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if action == actionForInput(selectedInput) {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                } else if action != .none, !inputsUsing(action).isEmpty {
                    Text(inputsUsing(action)).font(.caption2).foregroundStyle(.secondary)
                        .help(localized("Used by") + ": " + inputsUsing(action))
                }
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                action == actionForInput(selectedInput)
                    ? Color.accentColor.opacity(0.09)
                    : Color.clear
            )
        }
        .buttonStyle(.plain)
    }

    private func inputsUsing(_ action: MappedAction) -> String {
        ControllerInput.allCases.filter { actionForInput($0) == action }.map(\.shortLabel).joined(separator: ", ")
    }

    private func controlBadge(
        _ input: ControllerInput,
        selected: Bool
    ) -> some View {
        ZStack {
            Circle()
                .fill(selected ? Color.accentColor.opacity(0.10) : Color.white)
            Circle()
                .stroke(selected ? Color.accentColor : PS5Palette.border, lineWidth: 1.5)
            Text(controllerGlyph(input))
                .font(.system(size: controllerGlyph(input).count > 2 ? 9 : 17, weight: .medium))
                .foregroundStyle(.primary)
        }
        .frame(width: 42, height: 42)
    }

    private func actionDisplayName(_ action: MappedAction) -> String {
        action.label.components(separatedBy: " · ").last ?? action.label
    }

    private func controllerGlyph(_ input: ControllerInput) -> String {
        switch input {
        case .cross: "×"
        case .circle: "○"
        case .square: "□"
        case .triangle: "△"
        default: input.shortLabel
        }
    }

    private func inputDescription(_ input: ControllerInput) -> String {
        switch input {
        case .cross, .circle, .square, .triangle:
            String(localized: "Face button · Primary action", bundle: AppResources.localizationBundle)
        case .dpadUp, .dpadDown, .dpadLeft, .dpadRight:
            String(localized: "Directional pad", bundle: AppResources.localizationBundle)
        case .l1, .r1:
            String(localized: "Shoulder button", bundle: AppResources.localizationBundle)
        case .l2, .r2:
            String(localized: "Adaptive trigger", bundle: AppResources.localizationBundle)
        case .l3, .r3:
            String(localized: "Analogue stick click", bundle: AppResources.localizationBundle)
        case .create, .options:
            String(localized: "System button", bundle: AppResources.localizationBundle)
        case .ps:
            String(localized: "PlayStation button", bundle: AppResources.localizationBundle)
        case .touchpadClick:
            String(localized: "Touchpad click", bundle: AppResources.localizationBundle)
        case .microphone:
            String(localized: "Microphone button", bundle: AppResources.localizationBundle)
        }
    }

    private func calloutLine(
        _ callout: ShoulderCallout,
        imageWidth: CGFloat,
        imageHeight: CGFloat
    ) -> some View {
        ZStack {
            Path { path in
                let labelPoint = CGPoint(
                    x: imageWidth * callout.labelX,
                    y: imageHeight * callout.labelY
                )
                let targetPoint = CGPoint(
                    x: imageWidth * callout.targetX,
                    y: imageHeight * callout.targetY
                )
                let elbowX = imageWidth * callout.elbowX
                path.move(
                    to: CGPoint(
                        x: labelPoint.x + (callout.isLeading ? 20 : -20),
                        y: labelPoint.y
                    )
                )
                path.addLine(to: CGPoint(x: elbowX, y: labelPoint.y))
                path.addLine(to: targetPoint)
            }
            .stroke(Color.accentColor.opacity(0.72), lineWidth: 1.5)

            Circle()
                .fill(Color.accentColor.opacity(0.82))
                .frame(width: 6, height: 6)
                .position(
                    x: imageWidth * callout.targetX,
                    y: imageHeight * callout.targetY
                )
        }
    }

    private func calloutButton(
        _ callout: ShoulderCallout,
        imageWidth: CGFloat,
        imageHeight: CGFloat
    ) -> some View {
        Button {
            selectedInput = callout.input
        } label: {
            Text(callout.input.shortLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        }
        .buttonStyle(.plain)
        .position(
            x: imageWidth * callout.labelX,
            y: imageHeight * callout.labelY
        )
    }

    private var catalogCategories: [ActionCategory] {
        ActionSelectionCatalog.categories(for: profile, relevantOnly: relevantOnly)
    }

    private var filteredCategories: [ActionCategory] {
        catalogCategories.filter { (selectedCategory == nil || selectedCategory == $0) && !filteredActions(in: $0).isEmpty }
    }

    private func filteredActions(in category: ActionCategory) -> [MappedAction] {
        ActionSelectionCatalog.actions(in: category, for: profile, relevantOnly: relevantOnly).filter {
            ActionSelectionCatalog.matches($0, query: searchText)
        }
    }

    private func mappingButton(_ hotspot: MappingHotspot) -> some View {
        let selected = selectedInput == hotspot.input
        let mapped = actionForInput(hotspot.input) != .none
        let shape = RoundedRectangle(
            cornerRadius: hotspot.cornerRadius,
            style: .continuous
        )

        return Button {
            selectedInput = hotspot.input
        } label: {
            shape
                .fill(
                    selected
                        ? PS5Palette.acid.opacity(0.26)
                        : mapped
                            ? Color.accentColor.opacity(0.08)
                            : Color.white.opacity(0.18)
                )
                .frame(width: hotspot.width, height: hotspot.height)
                .overlay {
                    shape.stroke(
                        selected ? PS5Palette.acid : Color.accentColor,
                        lineWidth: selected ? 3 : 2
                    )
                }
                .shadow(
                    color: selected
                        ? PS5Palette.acid.opacity(0.45)
                        : Color.accentColor.opacity(0.2),
                    radius: 5
                )
            .frame(
                width: max(48, hotspot.width + 14),
                height: max(48, hotspot.height + 14)
            )
            .contentShape(
                RoundedRectangle(
                    cornerRadius: max(16, hotspot.cornerRadius + 7),
                    style: .continuous
                )
            )
        }
        .buttonStyle(.plain)
        .help("\(hotspot.input.label): \(actionForInput(hotspot.input).label)")
        .accessibilityLabel("\(hotspot.input.label), \(actionForInput(hotspot.input).label)")
    }

    private func actionIcon(_ action: MappedAction) -> String {
        switch action {
        case .codexSend: return "paperplane"
        case .codexStop: return "stop"
        case .codexReview: return "doc.text"
        case .codexDictation: return "mic"
        case .codexNewTask: return "plus.circle"
        case .codexNextTask: return "arrow.right.circle"
        case .codexPreviousTask: return "arrow.left.circle"
        case .codexBack: return "clock"
        case .codexFocus: return "person"
        case .mouseLeftClick, .mouseRightClick, .mouseMiddleClick:
            return "computermouse"
        case .copy, .paste, .cut, .selectAll:
            return "doc.on.clipboard"
        case .screenshotSelection:
            return "camera.viewfinder"
        case .codexAppSnapshot:
            return "macwindow"
        case .openClaude:
            return "sparkles"
        default:
            break
        }

        return switch action.category {
        case .codex: "terminal"
        case .claude: "sparkles"
        case .cursor: "cursorarrow"
        case .grokBot: "bubble.left.and.bubble.right"
        case .slack: "number"
        case .mail: "envelope"
        case .meeting: "video"
        case .presentation: "play.rectangle"
        case .communication: "bubble.left.and.bubble.right"
        case .files: "folder"
        case .creative: "slider.horizontal.3"
        case .terminal: "apple.terminal"
        case .mouse: "computermouse"
        case .navigation: "arrow.left.arrow.right"
        case .keyboard: "keyboard"
        case .browser: "globe"
        case .media: "play.circle"
        case .apps: "app"
        case .other: "ellipsis.circle"
        }
    }
}

struct ControllerLayoutPreview: View {
    let actionForInput: (ControllerInput) -> MappedAction
    let openMappings: () -> Void

    var body: some View {
        Button(action: openMappings) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Your controller, mapped")
                            .font(
                                .system(
                                    size: 17,
                                    weight: .semibold,
                                    design: .rounded
                                )
                            )
                        Text("Select any control to change its action.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label("Edit mappings", systemImage: "arrow.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }

                GeometryReader { proxy in
                    let imageWidth = min(
                        proxy.size.width * 0.74,
                        proxy.size.height * 1.5
                    )
                    let imageHeight = imageWidth / 1.5

                    ZStack {
                        LinearGradient(
                            colors: [
                                PS5Palette.heroBlue.opacity(0.34),
                                Color(red: 0.94, green: 0.97, blue: 1)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )

                        ZStack {
                            ProjectRasterImage(name: "dualsense-turn-1")
                                .scaledToFit()
                                .shadow(
                                    color: .black.opacity(0.12),
                                    radius: 18,
                                    y: 12
                                )

                            ForEach(mappingHotspots) { hotspot in
                                Circle()
                                    .fill(
                                        actionForInput(hotspot.input) == .none
                                            ? Color.white
                                            : Color.accentColor
                                    )
                                    .frame(width: 13, height: 13)
                                    .overlay {
                                        Circle()
                                            .stroke(Color.white, lineWidth: 2)
                                    }
                                    .shadow(
                                        color: .black.opacity(0.22),
                                        radius: 3,
                                        y: 1
                                    )
                                    .position(
                                        x: imageWidth * hotspot.x,
                                        y: imageHeight * hotspot.y
                                    )
                            }
                        }
                        .frame(width: imageWidth, height: imageHeight)
                    }
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: 13,
                            style: .continuous
                        )
                    )
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 308)
            .background(
                Color.white,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(PS5Palette.border, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open the interactive controller mapping")
    }
}

private struct MappingHotspot: Identifiable {
    let input: ControllerInput
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat

    var id: ControllerInput { input }

    init(
        input: ControllerInput,
        x: CGFloat,
        y: CGFloat,
        diameter: CGFloat
    ) {
        self.input = input
        self.x = x
        self.y = y
        width = diameter
        height = diameter
        cornerRadius = diameter / 2
    }

    init(
        input: ControllerInput,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat,
        cornerRadius: CGFloat
    ) {
        self.input = input
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
    }
}

private let mappingHotspots: [MappingHotspot] = [
    .init(
        input: .create,
        x: 0.337,
        y: 0.190,
        width: 24,
        height: 42,
        cornerRadius: 12
    ),
    .init(
        input: .options,
        x: 0.630,
        y: 0.210,
        width: 24,
        height: 42,
        cornerRadius: 12
    ),
    .init(input: .touchpadClick, x: 0.489, y: 0.242, diameter: 38),
    .init(input: .dpadUp, x: 0.279, y: 0.252, diameter: 42),
    .init(input: .dpadLeft, x: 0.241, y: 0.301, diameter: 42),
    .init(input: .dpadRight, x: 0.309, y: 0.303, diameter: 42),
    .init(input: .dpadDown, x: 0.270, y: 0.362, diameter: 42),
    .init(input: .triangle, x: 0.674, y: 0.250, diameter: 44),
    .init(input: .square, x: 0.619, y: 0.330, diameter: 44),
    .init(input: .circle, x: 0.719, y: 0.340, diameter: 44),
    .init(input: .cross, x: 0.663, y: 0.418, diameter: 44),
    .init(input: .l3, x: 0.337, y: 0.465, diameter: 68),
    .init(input: .r3, x: 0.557, y: 0.480, diameter: 68),
    .init(input: .ps, x: 0.459, y: 0.458, diameter: 34),
    .init(
        input: .microphone,
        x: 0.458,
        y: 0.530,
        width: 34,
        height: 18,
        cornerRadius: 9
    )
]

private struct ShoulderCallout: Identifiable {
    let input: ControllerInput
    let labelX: CGFloat
    let labelY: CGFloat
    let elbowX: CGFloat
    let targetX: CGFloat
    let targetY: CGFloat
    let isLeading: Bool

    var id: ControllerInput { input }
}

private let shoulderCallouts: [ShoulderCallout] = [
    .init(
        input: .l2,
        labelX: 0.180,
        labelY: 0.105,
        elbowX: 0.282,
        targetX: 0.305,
        targetY: 0.137,
        isLeading: true
    ),
    .init(
        input: .l1,
        labelX: 0.180,
        labelY: 0.185,
        elbowX: 0.282,
        targetX: 0.305,
        targetY: 0.166,
        isLeading: true
    ),
    .init(
        input: .r2,
        labelX: 0.828,
        labelY: 0.105,
        elbowX: 0.740,
        targetX: 0.707,
        targetY: 0.151,
        isLeading: false
    ),
    .init(
        input: .r1,
        labelX: 0.828,
        labelY: 0.185,
        elbowX: 0.740,
        targetX: 0.693,
        targetY: 0.181,
        isLeading: false
    )
]
