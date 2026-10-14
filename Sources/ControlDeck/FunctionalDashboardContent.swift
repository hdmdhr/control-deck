import SwiftUI

struct FunctionalDashboardContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var profiles: ProfileStore
    @ObservedObject private var controller: DualSenseControllerService
    @ObservedObject private var bluetoothMicrophone:
        BluetoothMicrophoneService
    @ObservedObject private var automation: CodexAutomation
    let openMappings: () -> Void

    init(model: AppModel, openMappings: @escaping () -> Void) {
        self.model = model
        _profiles = ObservedObject(wrappedValue: model.profiles)
        _controller = ObservedObject(wrappedValue: model.controller)
        _bluetoothMicrophone = ObservedObject(
            wrappedValue: model.bluetoothMicrophone
        )
        _automation = ObservedObject(wrappedValue: model.automation)
        self.openMappings = openMappings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("ControlDeck")
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                    Text("Controller status, task shortcuts and feedback at a glance.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                DashboardStatePill(state: model.currentState)
            }

            HStack(spacing: 12) {
                FunctionalStatusCard(
                    icon: controller.isConnected ? controller.transport.systemImage : "gamecontroller",
                    title: String(localized: "Controller", bundle: AppResources.localizationBundle),
                    value: controller.isConnected
                        ? controller.controllerName
                        : String(localized: "Offline", bundle: AppResources.localizationBundle),
                    detail: controller.isConnected
                        ? String(localized: "\(controller.transport.label) · \(Int(controller.batteryLevel * 100))% battery", bundle: AppResources.localizationBundle)
                        : String(localized: "Connect with USB or Bluetooth", bundle: AppResources.localizationBundle)
                )
                FunctionalStatusCard(
                    icon: profiles.activeKind.systemImage,
                    title: String(localized: "Active profile", bundle: AppResources.localizationBundle),
                    value: profiles.activeProfile.displayName,
                    detail: profiles.autoSwitchEnabled ? String(localized: "Switches with the foreground app", bundle: AppResources.localizationBundle) : String(localized: "Selected manually", bundle: AppResources.localizationBundle)
                )
                FunctionalStatusCard(
                    icon: "bolt.horizontal.circle",
                    title: String(localized: "Last controller action", bundle: AppResources.localizationBundle),
                    value: controller.lastInput,
                    detail: model.lastAction
                )
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Quick actions")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))

                HStack(spacing: 10) {
                    DashboardQuickAction(String(localized: "Send", bundle: AppResources.localizationBundle), icon: "paperplane.fill", color: PS5Palette.idle) {
                        model.perform(.sendMessage)
                    }
                    DashboardQuickAction(String(localized: "Stop", bundle: AppResources.localizationBundle), icon: "stop.fill", color: PS5Palette.thinking) {
                        model.perform(.interrupt)
                    }
                    DashboardQuickAction(String(localized: "Review", bundle: AppResources.localizationBundle), icon: "text.bubble.fill", color: PS5Palette.complete) {
                        model.perform(.toggleReview)
                    }
                    DashboardQuickAction(
                        model.pushToTalkActive ? String(localized: "Stop dictation", bundle: AppResources.localizationBundle) : String(localized: "Dictate", bundle: AppResources.localizationBundle),
                        icon: model.pushToTalkActive ? "mic.fill" : "mic",
                        color: PS5Palette.needsInput
                    ) {
                        model.toggleVoiceCapture()
                    }
                    DashboardQuickAction(String(localized: "New task", bundle: AppResources.localizationBundle), icon: "plus.circle.fill", color: PS5Palette.error) {
                        model.perform(.newTask)
                    }
                }
            }

            HStack(alignment: .top, spacing: 16) {
                ControllerLayoutPreview(
                    actionForInput: {
                        profiles.activeProfile.action(for: $0)
                    },
                    openMappings: openMappings
                )

                wirelessMicrophone
                    .frame(width: 340)
            }

            HStack(alignment: .top, spacing: 16) {
                recentTasks
                feedback
                    .frame(width: 300)
            }

            if !automation.accessibilityTrusted {
                PermissionPrompt {
                    model.requestAccessibility()
                }
            }
        }
    }

    private var wirelessMicrophone: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Controller microphone", systemImage: "mic.fill")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                Spacer()
                Circle()
                    .fill(microphoneStatusColor)
                    .frame(width: 9, height: 9)
            }

            Text(microphoneStatusTitle)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
            Text(microphoneStatusDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            microphoneMeter

            VStack(alignment: .leading, spacing: 5) {
                Text("MIC TEST")
                    .font(.caption2.weight(.bold))
                    .tracking(0.7)
                    .foregroundStyle(.secondary)
                Text(model.microphoneDiagnosticResult)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(
                        model.microphoneDiagnosticPassed
                            ? PS5Palette.complete
                            : Color.secondary
                    )
            }

            HStack(spacing: 9) {
                Button(
                    model.microphoneDiagnosticRunning
                        ? String(localized: "Testing…", bundle: AppResources.localizationBundle)
                        : String(localized: "Test 3 seconds", bundle: AppResources.localizationBundle)
                ) {
                    model.runWirelessMicrophoneDiagnostic()
                }
                .disabled(
                    controller.transport != .bluetooth ||
                        model.microphoneDiagnosticRunning ||
                        model.pushToTalkActive ||
                        model.selfTestRunning
                )

                Button(
                    model.pushToTalkActive
                        ? String(localized: "Stop dictation", bundle: AppResources.localizationBundle)
                        : String(localized: "Dictate in Codex", bundle: AppResources.localizationBundle)
                ) {
                    model.toggleVoiceCapture()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    !controller.isConnected ||
                        model.microphoneDiagnosticRunning ||
                        model.selfTestRunning
                )

                Button("Codex mic settings") {
                    model.openCodexMicrophoneSettings()
                }
            }

            Text(
                "Select DualSense Microphone once in Codex Settings → General. Your Mac’s system-default microphone is never changed."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 308, alignment: .topLeading)
        .background(
            Color.white,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(PS5Palette.border, lineWidth: 1)
        }
    }

    private var microphoneMeter: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.13))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [PS5Palette.complete, PS5Palette.acid],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(
                        width: proxy.size.width * min(
                            Double(bluetoothMicrophone.inputLevel) * 3.2,
                            1
                        )
                    )
            }
        }
        .frame(height: 8)
        .accessibilityLabel("Controller microphone level")
        .accessibilityValue(
            String(localized: "\(Int((bluetoothMicrophone.inputLevel * 100).rounded())) percent", bundle: AppResources.localizationBundle)
        )
    }

    private var microphoneStatusTitle: String {
        if model.pushToTalkActive {
            return String(localized: "Codex is listening", bundle: AppResources.localizationBundle)
        }
        if model.microphoneDiagnosticRunning {
            return String(localized: "Speak now", bundle: AppResources.localizationBundle)
        }
        if controller.transport == .bluetooth,
           bluetoothMicrophone.isPublished {
            return String(localized: "Bluetooth mic ready", bundle: AppResources.localizationBundle)
        }
        if controller.transport == .usb, model.audio.controllerAudioAvailable {
            return String(localized: "USB mic ready", bundle: AppResources.localizationBundle)
        }
        return String(localized: "Microphone offline", bundle: AppResources.localizationBundle)
    }

    private var microphoneStatusDetail: String {
        if controller.transport == .bluetooth {
            return bluetoothMicrophone.lastResult
        }
        if controller.transport == .usb {
            return model.audio.lastAudioResult
        }
        return String(localized: "Connect a DualSense by USB or Bluetooth.", bundle: AppResources.localizationBundle)
    }

    private var microphoneStatusColor: Color {
        if model.pushToTalkActive || model.microphoneDiagnosticRunning {
            return PS5Palette.needsInput
        }
        if controller.transport == .bluetooth,
           bluetoothMicrophone.isPublished {
            return PS5Palette.complete
        }
        if controller.transport == .usb, model.audio.controllerAudioAvailable {
            return PS5Palette.complete
        }
        return .gray
    }

    private var recentTasks: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recent Codex tasks")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                Spacer()
                Text("\(model.recentTasks.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(16)

            Divider()

            if model.recentTasks.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("No recent tasks yet")
                        .font(.headline)
                    Text("Start a Codex task and it will appear here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 190)
            } else {
                ForEach(Array(model.recentTasks.prefix(5).enumerated()), id: \.element.id) { index, task in
                    Button {
                        model.selectTask(task.id)
                    } label: {
                        RecentTaskRow(
                            task: task,
                            selected: model.selectedTaskID == task.id
                        )
                    }
                    .buttonStyle(.plain)
                    if index < min(model.recentTasks.count, 5) - 1 {
                        Divider().padding(.leading, 52)
                    }
                }
            }
        }
        .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(PS5Palette.border, lineWidth: 1)
        }
    }

    private var feedback: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Controller feedback")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
            Toggle("Task-state haptics", isOn: $model.statusHaptics)
            HStack {
                Text("Sound effects")
                Spacer()
                Picker("Sound effects", selection: $model.soundTheme) {
                    ForEach(SoundTheme.allCases) { theme in
                        Text(theme.label).tag(theme)
                    }
                }
                .labelsHidden()
                .frame(width: 110)
                Button {
                    model.previewSoundTheme()
                } label: {
                    Image(systemName: "speaker.wave.2")
                }
                .buttonStyle(.plain)
                .disabled(model.soundTheme == .off)
                .help("Preview the selected completion sound")
            }
            Text(model.soundTheme.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            Button(action: openMappings) {
                HStack {
                    Label("Edit button mappings", systemImage: "gamecontroller")
                    Spacer()
                    Image(systemName: "chevron.right")
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .semibold))
            .padding(.vertical, 4)
        }
        .padding(18)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(PS5Palette.border, lineWidth: 1)
        }
    }
}

private struct FunctionalStatusCard: View {
    let icon: String
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .lineLimit(1)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(PS5Palette.border, lineWidth: 1)
        }
    }
}

private struct DashboardQuickAction: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void

    init(_ title: String, icon: String, color: Color, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.color = color
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(PS5Palette.border, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct RecentTaskRow: View {
    let task: RecentCodexTask
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color(nsColor: task.state.color))
                .frame(width: 10, height: 10)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(task.shortMessage)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 5) {
                    if task.hasDistinctTitle {
                        Text(task.shortTitle)
                            .lineLimit(1)
                        Text("·")
                    }
                    Text(task.state.label)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            VStack {
                Text(task.updatedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Selected task")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 62)
        .background(
            selected ? Color.accentColor.opacity(0.08) : Color.clear
        )
    }
}

private struct DashboardStatePill: View {
    let state: CodexTaskState

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Color(nsColor: state.color))
                .frame(width: 8, height: 8)
            Text(state.label)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 11)
        .frame(height: 30)
        .background(Color(nsColor: state.color).opacity(0.12), in: Capsule())
    }
}

private struct PermissionPrompt: View {
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "accessibility")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Accessibility permission required")
                    .font(.headline)
                Text("Needed for pointer control, shortcuts and approval actions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Grant access", action: action)
                .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
    }
}
