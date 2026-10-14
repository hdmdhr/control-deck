import AppKit
import Combine
import Foundation
import SwiftUI

enum QuickTutorialStep: Int, CaseIterable, Identifiable, Sendable {
    case welcome
    case pairController
    case permissions
    case pointer
    case voiceAndCapture
    case profiles
    case advanced
    case ready

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .welcome: String(localized: "Meet ControlDeck", bundle: AppResources.localizationBundle)
        case .pairController: String(localized: "Connect your controller", bundle: AppResources.localizationBundle)
        case .permissions: String(localized: "Let the controller control your Mac", bundle: AppResources.localizationBundle)
        case .pointer: String(localized: "Move naturally around your Mac", bundle: AppResources.localizationBundle)
        case .voiceAndCapture: String(localized: "Speak and capture without leaving your work", bundle: AppResources.localizationBundle)
        case .profiles: String(localized: "Let the controls follow the app", bundle: AppResources.localizationBundle)
        case .advanced: String(localized: "Fine-tune it when you are ready", bundle: AppResources.localizationBundle)
        case .ready: String(localized: "You are ready", bundle: AppResources.localizationBundle)
        }
    }

    var detail: String {
        switch self {
        case .welcome:
            String(localized: "Your controller has a calm everyday layer for pointing, clicking, scrolling and speaking. Hold controls reveal extra power only when you need it.", bundle: AppResources.localizationBundle)
        case .pairController:
            String(localized: "Pair wirelessly by holding Create and PS together until the light bar pulses, or plug in a USB cable for an instant wired connection.", bundle: AppResources.localizationBundle)
        case .permissions:
            String(localized: "Accessibility lets ControlDeck move the pointer, click and send keyboard shortcuts. macOS keeps you in control and you can revoke access at any time.", bundle: AppResources.localizationBundle)
        case .pointer:
            String(localized: "The default layout is designed to replace a mouse for everyday work. Clicking and dragging behave like a real mouse, including text selection and moving windows.", bundle: AppResources.localizationBundle)
        case .voiceAndCapture:
            String(localized: "Dictate into any focused text field with L2. Codex and Claude keep their native voice experience; other apps use Apple’s local SpeechTranscriber. R2 captures and annotates the screen.", bundle: AppResources.localizationBundle)
        case .profiles:
            String(localized: "ControlDeck automatically chooses a layout for Codex, Chrome, Spotify, Claude and other popular apps. You can also switch explicitly with the profile wheel.", bundle: AppResources.localizationBundle)
        case .advanced:
            String(localized: "Everything below is optional. The defaults are ready to use, and these areas remain here when you want more control.", bundle: AppResources.localizationBundle)
        case .ready:
            String(localized: "Start with the everyday controls and change only what gets in your way. You can replay this tutorial from Setup whenever you like.", bundle: AppResources.localizationBundle)
        }
    }

    var systemImage: String {
        switch self {
        case .welcome: "gamecontroller.fill"
        case .pairController: "dot.radiowaves.left.and.right"
        case .permissions: "accessibility"
        case .pointer: "cursorarrow.motionlines"
        case .voiceAndCapture: "mic.and.signal.meter.fill"
        case .profiles: "circle.hexagongrid.fill"
        case .advanced: "slider.horizontal.3"
        case .ready: "checkmark.seal.fill"
        }
    }
}

struct QuickTutorialControl: Identifiable, Sendable {
    let control: String
    let action: String
    let detail: String

    var id: String { control + action }
}

enum QuickTutorialDestination: String, CaseIterable, Identifiable, Sendable {
    case buttonMapping
    case touchpad
    case pointer
    case screenCapture
    case shiftLayer
    case profiles
    case gyro
    case customize

    var id: String { rawValue }

    var title: String {
        switch self {
        case .buttonMapping: String(localized: "Button Mapping", bundle: AppResources.localizationBundle)
        case .touchpad: String(localized: "Touchpad", bundle: AppResources.localizationBundle)
        case .pointer: String(localized: "Pointer", bundle: AppResources.localizationBundle)
        case .screenCapture: String(localized: "Screen Capture", bundle: AppResources.localizationBundle)
        case .shiftLayer: String(localized: "Shift Layer", bundle: AppResources.localizationBundle)
        case .profiles: String(localized: "Profiles", bundle: AppResources.localizationBundle)
        case .gyro: String(localized: "Gyro", bundle: AppResources.localizationBundle)
        case .customize: String(localized: "Customize with Codex", bundle: AppResources.localizationBundle)
        }
    }

    var detail: String {
        switch self {
        case .buttonMapping: String(localized: "Change what every button does", bundle: AppResources.localizationBundle)
        case .touchpad: String(localized: "Tune scrolling and gestures", bundle: AppResources.localizationBundle)
        case .pointer: String(localized: "Adjust stick speed and acceleration", bundle: AppResources.localizationBundle)
        case .screenCapture: String(localized: "Choose editor and clipboard defaults", bundle: AppResources.localizationBundle)
        case .shiftLayer: String(localized: "Edit the eight-profile wheel", bundle: AppResources.localizationBundle)
        case .profiles: String(localized: "Manage layouts for different apps", bundle: AppResources.localizationBundle)
        case .gyro: String(localized: "Enable optional motion gestures", bundle: AppResources.localizationBundle)
        case .customize: String(localized: "Ask Codex to make a change for you", bundle: AppResources.localizationBundle)
        }
    }

    var systemImage: String {
        switch self {
        case .buttonMapping: "gamecontroller"
        case .touchpad: "hand.draw"
        case .pointer: "cursorarrow.motionlines"
        case .screenCapture: "viewfinder.rectangular"
        case .shiftLayer: "circle.hexagongrid.fill"
        case .profiles: "square.stack.3d.up"
        case .gyro: "gyroscope"
        case .customize: "sparkles"
        }
    }
}

enum QuickTutorialNavigationResult: Equatable, Sendable {
    case changedStep
    case completed
    case skipped
}

@MainActor
final class QuickTutorialStore: ObservableObject {
    @Published private(set) var isPresented = false
    @Published private(set) var currentStep: QuickTutorialStep = .welcome
    @Published private(set) var hasCompleted: Bool
    @Published private(set) var hasBeenOffered: Bool

    private let defaults: UserDefaults
    private static let completedKey = "quickTutorial.completed.v2"
    private static let offeredKey = "quickTutorial.offered.v2"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hasCompleted = defaults.bool(forKey: Self.completedKey)
        hasBeenOffered = defaults.bool(forKey: Self.offeredKey)
    }

    var stepNumber: Int { currentStep.rawValue + 1 }
    var stepCount: Int { QuickTutorialStep.allCases.count }
    var isFirstStep: Bool { currentStep == .welcome }
    var isLastStep: Bool { currentStep == .ready }

    func offerIfNeeded() {
        guard !hasCompleted, !hasBeenOffered, !isPresented else { return }
        start()
    }

    func start() {
        currentStep = .welcome
        isPresented = true
    }

    @discardableResult
    func next() -> QuickTutorialNavigationResult {
        guard !isLastStep,
              let next = QuickTutorialStep(rawValue: currentStep.rawValue + 1)
        else {
            complete()
            return .completed
        }
        currentStep = next
        return .changedStep
    }

    @discardableResult
    func previous() -> QuickTutorialNavigationResult {
        guard !isFirstStep,
              let previous = QuickTutorialStep(
                  rawValue: currentStep.rawValue - 1
              )
        else { return .changedStep }
        currentStep = previous
        return .changedStep
    }

    func complete() {
        hasCompleted = true
        hasBeenOffered = true
        defaults.set(true, forKey: Self.completedKey)
        defaults.set(true, forKey: Self.offeredKey)
        isPresented = false
    }

    func skip() {
        hasBeenOffered = true
        defaults.set(true, forKey: Self.offeredKey)
        isPresented = false
    }

    func handleControllerButton(
        _ input: ControllerInput
    ) -> QuickTutorialNavigationResult? {
        switch input {
        case .cross, .r1, .dpadRight, .options:
            return next()
        case .l1, .dpadLeft:
            return previous()
        case .circle:
            skip()
            return .skipped
        default:
            return nil
        }
    }
}

struct QuickTutorialView: View {
    @ObservedObject var store: QuickTutorialStore
    let controllerConnected: Bool
    let controllerName: String
    let accessibilityTrusted: Bool
    let pairingImage: NSImage?
    let openBluetoothSettings: () -> Void
    let requestAccessibility: () -> Void
    let openDestination: (QuickTutorialDestination) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 1_020, height: 700)
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Text("QUICK TUTORIAL")
                .font(.caption.weight(.bold))
                .tracking(1.4)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(QuickTutorialStep.allCases) { step in
                    Capsule()
                        .fill(
                            step.rawValue <= store.currentStep.rawValue
                                ? Color.accentColor
                                : Color.secondary.opacity(0.2)
                        )
                        .frame(width: step == store.currentStep ? 30 : 9, height: 7)
                }
            }
            Spacer()
            Text("\(store.stepNumber) of \(store.stepCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button("Skip tutorial") {
                store.skip()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 24)
        .frame(height: 56)
    }

    @ViewBuilder
    private var content: some View {
        if store.currentStep == .pairController {
            pairingContent
        } else if store.currentStep == .permissions {
            permissionContent
        } else if store.currentStep == .advanced {
            advancedContent
        } else {
            standardContent
        }
    }

    private var pairingContent: some View {
        HStack(spacing: 28) {
            DualSensePairingIllustration(image: pairingImage)
                .frame(width: 500, height: 333)

            VStack(alignment: .leading, spacing: 16) {
                Text(store.currentStep.title)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                Text(store.currentStep.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Label(
                    "Create is the small button above the D-pad",
                    systemImage: "info.circle.fill"
                )
                .font(.callout.weight(.medium))

                if controllerConnected {
                    Label(
                        "Connected: \(controllerName)",
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.headline)
                    .foregroundStyle(.green)
                } else {
                    Button("Open Bluetooth Settings", action: openBluetoothSettings)
                        .buttonStyle(.borderedProminent)
                }

                Divider()

                Label("USB is even simpler", systemImage: "cable.connector")
                    .font(.headline)
                Text(
                    "Connect a data-capable USB-C cable. ControlDeck detects the controller automatically; no Bluetooth pairing is needed."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(30)
    }

    private var permissionContent: some View {
        HStack(spacing: 34) {
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color.accentColor.opacity(0.1))
                Image(systemName: "accessibility")
                    .font(.system(size: 94, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 260, height: 260)

            VStack(alignment: .leading, spacing: 16) {
                Text(store.currentStep.title)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                Text(store.currentStep.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if accessibilityTrusted {
                    Label("Accessibility is enabled", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(.green)
                } else {
                    Button("Open Accessibility Settings", action: requestAccessibility)
                        .buttonStyle(.borderedProminent)
                    Text(
                        "Turn on ControlDeck in the list, then return here. The status updates automatically."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                Label(
                    "ControlDeck does not read passwords or personal files.",
                    systemImage: "lock.shield.fill"
                )
                .font(.callout.weight(.medium))
            }
            .frame(maxWidth: 430, alignment: .leading)
        }
        .padding(42)
    }

    private var standardContent: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 110, height: 110)
                Image(systemName: store.currentStep.systemImage)
                    .font(.system(size: 49, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(spacing: 8) {
                Text(store.currentStep.title)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                Text(store.currentStep.detail)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 660)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !controls.isEmpty {
                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 12
                ) {
                    ForEach(controls) { control in
                        tutorialControl(control)
                    }
                }
                .frame(maxWidth: 680)
            }
        }
        .padding(34)
    }

    private var advancedContent: some View {
        VStack(spacing: 18) {
            VStack(spacing: 7) {
                Image(systemName: store.currentStep.systemImage)
                    .font(.system(size: 38, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                Text(store.currentStep.title)
                    .font(.system(size: 27, weight: .semibold, design: .rounded))
                Text(store.currentStep.detail)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            LazyVGrid(
                columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ],
                spacing: 11
            ) {
                ForEach(QuickTutorialDestination.allCases) { destination in
                    Button {
                        store.complete()
                        openDestination(destination)
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Image(systemName: destination.systemImage)
                                .font(.title2)
                                .foregroundStyle(Color.accentColor)
                            Text(destination.title)
                                .font(.headline)
                            Text(destination.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, minHeight: 105, alignment: .topLeading)
                        .padding(13)
                        .background(
                            Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(26)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Back") {
                _ = store.previous()
            }
            .disabled(store.isFirstStep)
            .keyboardShortcut(.leftArrow, modifiers: [])

            Text("Controller: L1 / R1 to move · Circle to skip")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(store.isLastStep ? String(localized: "Finish", bundle: AppResources.localizationBundle) : String(localized: "Next", bundle: AppResources.localizationBundle)) {
                _ = store.next()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.rightArrow, modifiers: [])
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding(.horizontal, 24)
        .frame(height: 66)
    }

    private var controls: [QuickTutorialControl] {
        switch store.currentStep {
        case .welcome:
            [
                .init(control: String(localized: "Everyday", bundle: AppResources.localizationBundle), action: String(localized: "Point and work", bundle: AppResources.localizationBundle), detail: String(localized: "The controls you use constantly stay simple.", bundle: AppResources.localizationBundle)),
                .init(control: String(localized: "Hold controls", bundle: AppResources.localizationBundle), action: String(localized: "Reveal more", bundle: AppResources.localizationBundle), detail: String(localized: "Advanced actions stay out of the way until needed.", bundle: AppResources.localizationBundle))
            ]
        case .pairController, .permissions:
            []
        case .pointer:
            [
                .init(control: String(localized: "Left stick", bundle: AppResources.localizationBundle), action: String(localized: "Move pointer", bundle: AppResources.localizationBundle), detail: String(localized: "Cross clicks; hold Cross and move to drag or highlight.", bundle: AppResources.localizationBundle)),
                .init(control: String(localized: "Right stick / touchpad", bundle: AppResources.localizationBundle), action: String(localized: "Scroll", bundle: AppResources.localizationBundle), detail: String(localized: "Scroll vertically or horizontally with analogue control.", bundle: AppResources.localizationBundle))
            ]
        case .voiceAndCapture:
            [
                .init(control: String(localized: "L2", bundle: AppResources.localizationBundle), action: String(localized: "Dictate anywhere", bundle: AppResources.localizationBundle), detail: String(localized: "Focus a text field, then tap for hands-free dictation or hold for push-to-talk. Apple transcription stays on this Mac.", bundle: AppResources.localizationBundle)),
                .init(control: String(localized: "R2", bundle: AppResources.localizationBundle), action: String(localized: "Capture", bundle: AppResources.localizationBundle), detail: String(localized: "Select an area, copy it, then annotate or dismiss immediately.", bundle: AppResources.localizationBundle))
            ]
        case .profiles:
            [
                .init(control: String(localized: "Automatic", bundle: AppResources.localizationBundle), action: String(localized: "Follow the foreground app", bundle: AppResources.localizationBundle), detail: String(localized: "Curated profiles match popular apps without extra work.", bundle: AppResources.localizationBundle)),
                .init(control: String(localized: "Hold Options + left stick", bundle: AppResources.localizationBundle), action: String(localized: "Choose a profile", bundle: AppResources.localizationBundle), detail: String(localized: "Release Options on one of the eight app-logo slots.", bundle: AppResources.localizationBundle))
            ]
        case .ready:
            [
                .init(control: String(localized: "Touchpad click", bundle: AppResources.localizationBundle), action: String(localized: "Show context", bundle: AppResources.localizationBundle), detail: String(localized: "See the current profile and important mappings at any time.", bundle: AppResources.localizationBundle)),
                .init(control: String(localized: "Hold touchpad click", bundle: AppResources.localizationBundle), action: String(localized: "Switch apps", bundle: AppResources.localizationBundle), detail: String(localized: "Use the right stick or D-pad Left/Right, release the touchpad to select, or Circle to cancel.", bundle: AppResources.localizationBundle)),
                .init(control: String(localized: "Setup", bundle: AppResources.localizationBundle), action: String(localized: "Replay tutorial", bundle: AppResources.localizationBundle), detail: String(localized: "This walkthrough always remains available here.", bundle: AppResources.localizationBundle))
            ]
        case .advanced:
            []
        }
    }

    private func tutorialControl(_ item: QuickTutorialControl) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Text(item.control)
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 125, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.action)
                    .font(.headline)
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(15)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }
}

private struct DualSensePairingIllustration: View {
    let image: NSImage?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.accentColor.opacity(0.08),
                                Color(nsColor: .controlBackgroundColor)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(8)
                } else {
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 150, weight: .light))
                        .foregroundStyle(.secondary)
                }

                pairingMarker(
                    String(localized: "CREATE", bundle: AppResources.localizationBundle),
                    at: CGPoint(x: 0.335, y: 0.205),
                    in: proxy.size
                )
                pairingMarker(
                    String(localized: "PS", bundle: AppResources.localizationBundle),
                    at: CGPoint(x: 0.46, y: 0.485),
                    in: proxy.size
                )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "DualSense controller with the Create and PS buttons highlighted"
        )
    }

    private func pairingMarker(
        _ label: String,
        at point: CGPoint,
        in size: CGSize
    ) -> some View {
        VStack(spacing: 4) {
            Circle()
                .stroke(Color.accentColor, lineWidth: 4)
                .background(Circle().fill(Color.accentColor.opacity(0.15)))
                .frame(width: label == String(localized: "PS", bundle: AppResources.localizationBundle) ? 50 : 42, height: label == String(localized: "PS", bundle: AppResources.localizationBundle) ? 50 : 42)
            Text(label)
                .font(.caption2.weight(.black))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.ultraThickMaterial, in: Capsule())
        }
        .position(x: size.width * point.x, y: size.height * point.y)
    }
}
