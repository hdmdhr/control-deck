import AppKit
import SwiftUI

@main
struct ControlDeckApp: App {
    @NSApplicationDelegateAdaptor(ControlDeckAppDelegate.self)
    private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("ControlDeck", id: "dashboard") {
            DashboardView(model: model)
                .onAppear { model.start() }
        }
        .defaultSize(width: 1565, height: 1005)
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuContent(model: model)
                .onAppear { model.start() }
        } label: {
            Image(systemName: model.controller.isConnected ? "gamecontroller.fill" : "gamecontroller")
        }
    }
}

private final class ControlDeckAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

private struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle()
                    .fill(Color(nsColor: model.currentState.color))
                    .frame(width: 9, height: 9)
                Text(model.controller.isConnected ? String(localized: "DualSense · \(model.currentState.label)", bundle: AppResources.localizationBundle) : String(localized: "DualSense disconnected", bundle: AppResources.localizationBundle))
                    .font(.headline)
            }
            Text(model.lastAction)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Divider()

            Button("Open ControlDeck") {
                openWindow(id: "dashboard")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("New Codex task") {
                model.perform(.newTask)
            }
            Button("Run hardware self-test") {
                model.runSelfTest()
            }
            .disabled(model.selfTestRunning || !model.controller.isConnected)

            Divider()

            Button("Quit ControlDeck") {
                NSApp.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 280)
    }
}
