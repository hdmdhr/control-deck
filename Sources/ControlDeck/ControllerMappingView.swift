import SwiftUI

struct ControllerMappingView: View {
    @Binding var selectedInput: ControllerInput
    let profileKind: ProfileKind
    let actionForInput: (ControllerInput) -> MappedAction
    let setAction: (MappedAction, ControllerInput) -> Void
    let resetSelected: () -> Void

    @State private var searchText = ""

    var body: some View {
        GeometryReader { proxy in
            let inspectorWidth = proxy.size.width * (406.0 / 1_241.0)
            let inspectorPadding = inspectorWidth * (28.0 / 406.0)

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Button Mapping")
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                        Text("Select a control on the controller, then choose what it does.")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 54)
                    .padding(.top, 30)
                    .padding(.bottom, 10)

                    controllerCanvas
                }
                Divider()
                inspector(horizontalPadding: inspectorPadding)
                    .frame(width: inspectorWidth)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
    }

    private var controllerCanvas: some View {
        GeometryReader { proxy in
            let imageWidth = min(
                proxy.size.width * 1.29,
                max(620, (proxy.size.height - 118) * 1.5),
                1_080
            )
            let imageHeight = imageWidth / 1.5
            let imageTop: CGFloat = 15

            ZStack {
                Color.white

                ZStack {
                    ProjectRasterImage(name: "dualsense-turn-1")
                        .scaledToFit()
                        .shadow(color: .black.opacity(0.15), radius: 24, y: 16)
                        .accessibilityLabel("Tilted DualSense controller with selectable controls")

                    ForEach(shoulderCallouts) { callout in
                        calloutLine(callout, imageWidth: imageWidth, imageHeight: imageHeight)
                    }

                    ForEach(mappingHotspots) { hotspot in
                        mappingButton(hotspot)
                            .position(
                                x: imageWidth * hotspot.x,
                                y: imageHeight * hotspot.y
                            )
                    }

                    ForEach(shoulderCallouts) { callout in
                        calloutButton(callout, imageWidth: imageWidth, imageHeight: imageHeight)
                    }
                }
                .frame(width: imageWidth, height: imageHeight)
                .position(
                    x: proxy.size.width / 2 - imageWidth * 0.027,
                    y: imageTop + imageHeight / 2
                )

                HStack {
                    Label("Click any highlighted control", systemImage: "info.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .frame(maxHeight: .infinity, alignment: .top)

                selectedInputSummary
                    .frame(width: min(proxy.size.width - 96, 550))
                    .position(
                        x: proxy.size.width / 2,
                        y: proxy.size.height - 96
                    )
            }
        }
    }

    private func inspector(horizontalPadding: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                controlBadge(selectedInput, selected: true)
                Text(selectedInput.label)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
            }
            .padding(.top, 12)

            Text("Current action")
                .font(.caption)
                .foregroundStyle(.secondary)
            Menu {
                ForEach(ActionCategory.allCases) { category in
                    Menu(category.label) {
                        ForEach(MappedAction.allCases.filter { $0.category == category }) { action in
                            Button {
                                setAction(action, selectedInput)
                            } label: {
                                if action == actionForInput(selectedInput) {
                                    Label(action.label, systemImage: "checkmark")
                                } else {
                                    Text(action.label)
                                }
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: actionIcon(actionForInput(selectedInput)))
                        .font(.system(size: 17))
                    Text(actionForInput(selectedInput).label)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(.plain)
            .tint(Color.accentColor)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(
                Color.accentColor.opacity(0.09),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search actions", text: $searchText)
                    .textFieldStyle(.plain)
            }
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(PS5Palette.border, lineWidth: 1)
                }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(filteredCategories) { category in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(category.label)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            VStack(spacing: 0) {
                                ForEach(filteredActions(in: category)) { action in
                                    actionRow(action)
                                    if action != filteredActions(in: category).last {
                                        Divider()
                                            .padding(.leading, 34)
                                    }
                                }
                            }
                            .background(
                                Color.white,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(PS5Palette.border, lineWidth: 1)
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            Button(action: resetSelected) {
                Text("Reset \(selectedInput.label)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Color.white)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.red.opacity(0.75), lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.top, 18)
        .padding(.bottom, 44)
        .background(Color.white)
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
                    .lineLimit(1)
                Spacer(minLength: 0)
                if action == actionForInput(selectedInput) {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .frame(height: 29)
            .background(
                action == actionForInput(selectedInput)
                    ? Color.accentColor.opacity(0.09)
                    : Color.clear
            )
        }
        .buttonStyle(.plain)
    }

    private var selectedInputSummary: some View {
        HStack(spacing: 14) {
            controlBadge(selectedInput, selected: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(selectedInput.label)
                    .font(.headline)
                Text(inputDescription(selectedInput))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label(
                actionForInput(selectedInput).label,
                systemImage: actionIcon(actionForInput(selectedInput))
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(.horizontal, 18)
        .frame(height: 76)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(PS5Palette.border, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.035), radius: 10, y: 4)
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

    private var filteredCategories: [ActionCategory] {
        let preferred = profileKind.preferredActionCategories
        let source = searchText.isEmpty ? preferred : ActionCategory.allCases
        return source.filter { !filteredActions(in: $0).isEmpty }
    }

    private func filteredActions(in category: ActionCategory) -> [MappedAction] {
        let actions: [MappedAction]
        if searchText.isEmpty {
            actions = MappedAction.allCases.filter {
                $0.category == category
            }
        } else {
            actions = MappedAction.allCases
        }

        if searchText.isEmpty {
            return actions
        }
        return actions.filter { action in
            action.category == category &&
                action.label.localizedCaseInsensitiveContains(searchText)
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
        case .openClaude:
            return "sparkles"
        default:
            break
        }

        return switch action.category {
        case .codex: "terminal"
        case .claude: "sparkles"
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
