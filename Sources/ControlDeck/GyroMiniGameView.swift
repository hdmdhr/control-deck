import Combine
import OSLog
import SwiftUI
import WebKit

struct GyroTelemetryMeters: View {
    @ObservedObject var telemetry: GyroTelemetry

    var body: some View {
        HStack(spacing: 18) {
            meter("Tilt X", value: telemetry.sample.gravityX, color: .blue)
            meter("Tilt Y", value: telemetry.sample.gravityY, color: .purple)
            meter(
                "Shake",
                value: min(
                    hypot(
                        telemetry.sample.accelerationX,
                        telemetry.sample.accelerationY
                    ) / 3.6,
                    1
                ),
                color: .orange,
                signed: false
            )
        }
    }

    private func meter(
        _ label: String,
        value: Double,
        color: Color,
        signed: Bool = true
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: "%+.2f", value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            GeometryReader { proxy in
                ZStack(alignment: signed ? .center : .leading) {
                    Capsule().fill(Color.secondary.opacity(0.13))
                    Capsule()
                        .fill(color)
                        .frame(
                            width: proxy.size.width * min(abs(value), 1)
                        )
                }
            }
            .frame(height: 7)
        }
    }
}

private enum GyroGameCommandKind: Equatable {
    case course
    case start
    case reset
    case stop
}

private struct GyroGameCommand: Equatable {
    var identifier = 0
    var kind = GyroGameCommandKind.course
}

struct GyroMiniGameView: View {
    @ObservedObject var model: AppModel

    @AppStorage("gyroGameBestMilliseconds")
    private var bestMilliseconds = 0.0
    @State private var seed = 8127
    @State private var playing = false
    @State private var completedTime: Double?
    @State private var command = GyroGameCommand()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Tilt Run")
                        .font(.headline)
                    Text("A new floating course is generated from every seed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let completedTime {
                    Label(
                        formattedTime(completedTime),
                        systemImage: "trophy.fill"
                    )
                    .foregroundStyle(.green)
                    .font(.callout.weight(.semibold))
                }
                Button("New course", systemImage: "shuffle") {
                    newCourse()
                }
                .disabled(playing)
                if playing {
                    Button("Reset") { send(.reset) }
                    Button("Stop") { stop() }
                } else {
                    Button("Start run") { start() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.controller.motionAvailable)
                }
            }

            TiltRunWebView(
                telemetry: model.gyroTelemetry,
                seed: seed,
                bestMilliseconds: bestMilliseconds,
                command: command,
                onStartRequested: start,
                onFinished: finish,
                onFall: model.gyroGameDidFall,
                onToken: model.gyroGameDidCollectToken
            )
            .frame(minHeight: 360, idealHeight: 420)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            }

            Label(
                playing
                    ? "Gyro shortcuts are paused during the run. Falling returns you to the latest checkpoint with a two-second penalty."
                    : "Start the timer here or with the button inside the course.",
                systemImage: "gyroscope"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .onDisappear { stop() }
    }

    private func start() {
        guard model.controller.motionAvailable else { return }
        completedTime = nil
        playing = true
        model.setGyroGameActive(true)
        send(.start)
    }

    private func stop() {
        guard playing || model.gyroGameActive else { return }
        playing = false
        model.setGyroGameActive(false)
        send(.stop)
    }

    private func finish(milliseconds: Double) {
        completedTime = milliseconds
        if bestMilliseconds == 0 || milliseconds < bestMilliseconds {
            bestMilliseconds = milliseconds
        }
        playing = false
        model.setGyroGameActive(false)
        model.gyroGameDidReachGoal()
    }

    private func newCourse() {
        seed = Int.random(in: 1000...9999)
        completedTime = nil
        send(.course)
    }

    private func send(_ kind: GyroGameCommandKind) {
        command = GyroGameCommand(
            identifier: command.identifier + 1,
            kind: kind
        )
    }

    private func formattedTime(_ milliseconds: Double) -> String {
        let hundredths = Int(milliseconds / 10)
        let minutes = hundredths / 6000
        let seconds = (hundredths / 100) % 60
        return String(
            format: "%02d:%02d.%02d",
            minutes,
            seconds,
            hundredths % 100
        )
    }
}

private struct TiltRunWebView: NSViewRepresentable {
    @ObservedObject var telemetry: GyroTelemetry
    var seed: Int
    var bestMilliseconds: Double
    var command: GyroGameCommand
    var onStartRequested: () -> Void
    var onFinished: (Double) -> Void
    var onFall: () -> Void
    var onToken: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(
            context.coordinator,
            name: "gyroGame"
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.underPageBackgroundColor = .clear

        let resourceURL = AppResources.bundle?.url(
            forResource: "index",
            withExtension: "html",
            subdirectory: "GyroGame"
        ) ?? AppResources.bundle?.url(forResource: "index", withExtension: "html")
        if let resourceURL {
            webView.loadFileURL(
                resourceURL,
                allowingReadAccessTo: resourceURL.deletingLastPathComponent()
            )
        } else {
            webView.loadHTMLString(
                "<p style='font: 14px sans-serif'>Tilt Run resources are missing.</p>",
                baseURL: nil
            )
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(webView)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: "gyroGame"
        )
        webView.evaluateJavaScript("window.controlDeckGame?.stop()")
        webView.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: TiltRunWebView
        private let logger = Logger(
            subsystem: "com.ianhansel.controldeck",
            category: "gyro-game"
        )
        private var isReady = false
        private var lastCommandIdentifier = -1
        private var lastSeed = -1
        private var lastBest = -1.0
        private var motionGate = MotionSampleForwardingGate()
        private weak var webView: WKWebView?

        init(parent: TiltRunWebView) {
            self.parent = parent
        }

        func update(_ webView: WKWebView) {
            self.webView = webView
            guard isReady else { return }
            let x = parent.telemetry.sample.gravityX
            let y = parent.telemetry.sample.gravityY
            if motionGate.shouldForward(x: x, y: y) {
                evaluate(
                    "window.controlDeckGame?.setMotion(\(number(x)), \(number(y)))"
                )
            }
            if parent.seed != lastSeed {
                lastSeed = parent.seed
                evaluate("window.controlDeckGame?.setCourse(\(parent.seed))")
            }
            if parent.bestMilliseconds != lastBest {
                lastBest = parent.bestMilliseconds
                evaluate(
                    "window.controlDeckGame?.setBest(\(number(parent.bestMilliseconds)))"
                )
            }
            guard parent.command.identifier != lastCommandIdentifier else {
                return
            }
            lastCommandIdentifier = parent.command.identifier
            switch parent.command.kind {
            case .course:
                evaluateCritical(
                    "window.controlDeckGame?.setCourse(\(parent.seed))",
                    operation: "set course"
                )
            case .start:
                evaluateCritical(
                    "window.controlDeckGame?.start(\(parent.seed), \(number(parent.bestMilliseconds)))",
                    operation: "start run"
                )
            case .reset:
                evaluateCritical(
                    "window.controlDeckGame?.reset()",
                    operation: "reset run"
                )
            case .stop:
                evaluateCritical(
                    "window.controlDeckGame?.stop()",
                    operation: "stop run"
                )
            }
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "gyroGame",
                  let body = message.body as? [String: Any],
                  let type = body["type"] as? String
            else { return }
            switch type {
            case "ready":
                motionGate.reset()
                lastCommandIdentifier = -1
                lastSeed = -1
                lastBest = -1
                isReady = true
                logger.notice("Tilt Run JavaScript bridge ready")
                if let webView { update(webView) }
            case "start":
                logger.notice("Tilt Run start requested from WebKit")
                parent.onStartRequested()
            case "finish":
                guard let milliseconds = body["elapsedMilliseconds"] as? Double
                else { return }
                parent.onFinished(milliseconds)
            case "fall":
                parent.onFall()
            case "token":
                parent.onToken()
            default:
                break
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(url.isFileURL || url.absoluteString == "about:blank" ? .allow : .cancel)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            logger.error("Tilt Run WebKit process terminated; reloading")
            isReady = false
            webView.reload()
        }

        private func evaluate(_ script: String) {
            webView?.evaluateJavaScript(script, completionHandler: nil)
        }

        private func evaluateCritical(_ script: String, operation: String) {
            webView?.evaluateJavaScript(script) { [logger] _, error in
                if let error {
                    logger.error(
                        "Tilt Run \(operation, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                    )
                } else {
                    logger.notice(
                        "Tilt Run \(operation, privacy: .public) delivered"
                    )
                }
            }
        }

        private func number(_ value: Double) -> String {
            String(
                format: "%.6f",
                locale: Locale(identifier: "en_US_POSIX"),
                value
            )
        }
    }
}
