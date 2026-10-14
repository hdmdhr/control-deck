import AppKit
import Foundation

@MainActor
final class CodexExtensionService: ObservableObject {
    @Published private(set) var isInstalled = false
    @Published private(set) var isRunning = false
    @Published private(set) var status =
        "Install the readable local controller workspace to customize profiles from Codex."
    @Published private(set) var lastOutput = ""

    init() {
        refresh()
    }

    func refresh() {
        let workspace = customizationWorkspace()
        isInstalled = hasControllerTools(in: workspace)
        if isInstalled {
            status =
                "Controller skill and local profile tools are ready for Codex."
        }
    }

    func install() {
        guard !isRunning else { return }
        isRunning = true
        status = "Installing the local controller workspace…"
        do {
            let paths = try installBundledFiles()
            isInstalled = true
            status =
                "Installed locally. No command-line programs were launched."
            lastOutput = """
            Workspace: \(paths.workspace.path)
            Skill: \(paths.skill.path)
            MCP server: \(paths.server.path)

            These are readable local files. Codex will only open them after you
            explicitly choose “Open task in Codex”.
            """
        } catch {
            status = error.localizedDescription
            lastOutput = error.localizedDescription
        }
        isRunning = false
    }

    func runCustomization(_ request: String) {
        let trimmed = request.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty, !isRunning else { return }

        let workspace = customizationWorkspace()
        guard hasControllerTools(in: workspace) else {
            status = "Install the controller workspace first."
            return
        }

        let prompt = """
        Use $control-deck-customizer and the control-deck MCP tools.
        Make the narrowest safe controller change that satisfies this request:

        \(trimmed)

        Prefer profile tools. Modify source only when the requested behavior
        cannot be represented by an existing profile, and verify source changes
        with ./scripts/test.sh and swift build -c debug when those files exist.
        Do not download or execute unrelated software.
        """
        var components = URLComponents()
        components.scheme = "codex"
        components.host = "new"
        components.queryItems = [
            URLQueryItem(name: "prompt", value: prompt),
            URLQueryItem(name: "path", value: workspace.path)
        ]
        guard let url = components.url, NSWorkspace.shared.open(url) else {
            status = "Could not open the Codex desktop app."
            lastOutput =
                "Open Codex manually and use this workspace:\n\(workspace.path)"
            return
        }
        status = "Opened a controller customization task in Codex."
        lastOutput = """
        Codex workspace: \(workspace.path)

        The request was placed in a new Codex task for you to review and send.
        The controller app did not launch a command-line executable.
        """
    }

    func openCodexSkills() {
        if let url = URL(string: "codex://skills") {
            NSWorkspace.shared.open(url)
        }
    }

    func revealInstalledFiles() {
        let workspace = customizationWorkspace()
        NSWorkspace.shared.activateFileViewerSelecting([workspace])
    }

    private func installBundledFiles() throws -> (
        server: URL,
        skill: URL,
        workspace: URL
    ) {
        let fileManager = FileManager.default
        let workspace = installedWorkspace()
        let tools = workspace.appendingPathComponent(
            "Tools",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: tools,
            withIntermediateDirectories: true
        )

        guard let bundledServer = AppResources.bundle?.url(
            forResource: "control_deck_mcp",
            withExtension: "py"
        ) else {
            throw ExtensionError.missingResource("MCP server")
        }
        let installedServer = tools.appendingPathComponent(
            "control_deck_mcp.py"
        )
        try replace(bundledServer, at: installedServer)

        let skill = workspace.appendingPathComponent(
            ".agents/skills/control-deck-customizer",
            isDirectory: true
        )
        let agents = skill.appendingPathComponent(
            "agents",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: agents,
            withIntermediateDirectories: true
        )
        guard let bundledSkill = AppResources.bundle?.url(
            forResource: "SKILL",
            withExtension: "md"
        ), let bundledMetadata = AppResources.bundle?.url(
            forResource: "openai",
            withExtension: "yaml"
        ) else {
            throw ExtensionError.missingResource("Codex skill")
        }
        try replace(
            bundledSkill,
            at: skill.appendingPathComponent("SKILL.md")
        )
        try replace(
            bundledMetadata,
            at: agents.appendingPathComponent("openai.yaml")
        )

        let configDirectory = workspace.appendingPathComponent(
            ".codex",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: configDirectory,
            withIntermediateDirectories: true
        )
        let config = """
        [mcp_servers.control-deck]
        command = "/usr/bin/python3"
        args = ["\(tomlEscaped(installedServer.path))"]
        cwd = "\(tomlEscaped(workspace.path))"
        """
        try config.write(
            to: configDirectory.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
        return (installedServer, skill, workspace)
    }

    private func replace(_ source: URL, at destination: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
    }

    private func customizationWorkspace() -> URL {
        let root = projectRoot()
        if hasControllerTools(in: root) {
            return root
        }
        return installedWorkspace()
    }

    private func installedWorkspace() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/ControlDeck/Customization",
                isDirectory: true
            )
    }

    private func hasControllerTools(in workspace: URL) -> Bool {
        let fileManager = FileManager.default
        let required = [
            ".codex/config.toml",
            ".agents/skills/control-deck-customizer/SKILL.md"
        ]
        return required.allSatisfy {
            fileManager.fileExists(
                atPath: workspace.appendingPathComponent($0).path
            )
        }
    }

    private func projectRoot() -> URL {
        let fileManager = FileManager.default
        let current = URL(
            fileURLWithPath: fileManager.currentDirectoryPath,
            isDirectory: true
        )
        if fileManager.fileExists(
            atPath: current.appendingPathComponent("Package.swift").path
        ) {
            return current
        }
        let candidate = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        if fileManager.fileExists(
            atPath: candidate.appendingPathComponent("Package.swift").path
        ) {
            return candidate
        }
        return installedWorkspace()
    }

    private func tomlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

private enum ExtensionError: LocalizedError {
    case missingResource(String)

    var errorDescription: String? {
        switch self {
        case let .missingResource(name):
            "\(name) is missing from this build."
        }
    }
}
