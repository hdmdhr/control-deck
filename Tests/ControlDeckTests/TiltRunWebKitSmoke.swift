import AppKit
import Foundation
import WebKit

final class TiltRunBridgeProbe: NSObject, WKScriptMessageHandler {
    private(set) var passed = false
    private(set) var failure = "Tilt Run did not become ready"
    private var webView: WKWebView?
    private var expectedStart = "START RUN"

    func load(resources: URL) {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(self, name: "gyroGame")
        if CommandLine.arguments.count > 2 {
            let language = CommandLine.arguments[2]
            let url = resources.deletingLastPathComponent()
                .appendingPathComponent("\(language).lproj/Localizable.strings")
            let table = try! PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as! [String: String]
            expectedStart = table["Start run"]!
            let messages = ["start": expectedStart, "hint": table["Tilt the controller to roll"]!]
            let data = try! JSONSerialization.data(withJSONObject: messages)
            let json = String(data: data, encoding: .utf8)!
            configuration.userContentController.addUserScript(WKUserScript(
                source: "window.controlDeckGameStrings = \(json);",
                injectionTime: .atDocumentStart, forMainFrameOnly: true
            ))
        }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 520), configuration: configuration)
        self.webView = webView
        webView.loadFileURL(
            resources.appendingPathComponent("index.html"),
            allowingReadAccessTo: resources
        )
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String
        else { return }
        switch type {
        case "ready":
            webView?.evaluateJavaScript(
                "document.querySelector('#start-button').textContent"
            ) { [weak self] value, error in
                guard let self else { return }
                guard error == nil, value as? String == self.expectedStart else {
                    self.failure = "Localized start label mismatch: \(value ?? "nil")"
                    return
                }
                self.webView?.evaluateJavaScript("document.querySelector('#start-button').click()")
            }
        case "start":
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.verifyStartedState()
            }
        default:
            break
        }
    }

    private func verifyStartedState() {
        let script = """
        JSON.stringify({
          timer: document.querySelector('#timer').textContent,
          hidden: document.querySelector('#status').classList.contains('hidden'),
          playing: window.controlDeckGame.isPlaying()
        })
        """
        webView?.evaluateJavaScript(script) { [weak self] value, error in
            guard let self else { return }
            if let error {
                failure = "Started-state read failed: \(error.localizedDescription)"
                return
            }
            guard let json = value as? String,
                  let data = json.data(using: .utf8),
                  let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  state["hidden"] as? Bool == true,
                  state["playing"] as? Bool == true
            else {
                failure = "Start click did not enter playing state: \(value ?? "nil")"
                return
            }
            passed = true
        }
    }
}

let resources = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let probe = TiltRunBridgeProbe()
probe.load(resources: resources)
let deadline = Date().addingTimeInterval(8)
while !probe.passed, Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
}

if probe.passed {
    print("PASS: Tilt Run native WebKit start bridge")
} else {
    FileHandle.standardError.write(Data("FAIL: \(probe.failure)\n".utf8))
    exit(1)
}
