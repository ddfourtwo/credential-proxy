import SwiftUI
import CredentialProxyCore

struct CredentialProxyApp: App {
    @ObservedObject private var serverManager = ServerManager.shared
    @StateObject private var apiClient = APIClient()
    @State private var isUnlocked = false
    @State private var showMCPRegistered = false

    var body: some Scene {
        MenuBarExtra {
            if !isUnlocked {
                PinEntryView {
                    isUnlocked = true
                    // Auto-register MCP server on first launch
                    if Self.registerMCPIfNeeded() {
                        showMCPRegistered = true
                    }
                    // Auto-enable daemon mode (export key so daemon can decrypt secrets)
                    if !SealKeyManager.shared.daemonKeyExists {
                        _ = try? SealKeyManager.shared.exportKeyForDaemon()
                    }
                    ServerManager.startShared()
                }
                .padding(4)
            } else {
                MenuBarView()
                    .environmentObject(serverManager)
                    .environmentObject(apiClient)
            }
        } label: {
            Image(systemName: isUnlocked && serverManager.isRunning ? "key.fill" : "key")
        }
        .menuBarExtraStyle(.window)

        Window("Credential Proxy", id: "main") {
            CredentialListView()
                .environmentObject(serverManager)
                .environmentObject(apiClient)
                .frame(minWidth: 600, minHeight: 400)
        }

        Settings {
            SettingsView()
                .environmentObject(serverManager)
        }
    }

    // MARK: - MCP Auto-Registration

    /// Register credential-proxy as an MCP server in ~/.claude.json if not already present.
    /// Returns true if registration was performed (first launch).
    static func registerMCPIfNeeded() -> Bool {
        guard let bundlePath = Bundle.main.resourcePath else { return false }
        let relayIndex = bundlePath + "/mcp-relay/index.js"

        // Verify the relay exists in the bundle
        guard FileManager.default.fileExists(atPath: relayIndex) else {
            NSLog("[MCP] relay not found at \(relayIndex)")
            return false
        }

        let claudeJsonPath = NSHomeDirectory() + "/.claude.json"
        let serverName = "credential-proxy"

        var config: [String: Any]
        if let data = FileManager.default.contents(atPath: claudeJsonPath),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            config = parsed
        } else {
            config = [:]
        }

        var mcpServers = config["mcpServers"] as? [String: Any] ?? [:]

        // Already registered — check if path is current
        if let existing = mcpServers[serverName] as? [String: Any],
           let args = existing["args"] as? [String],
           args.first == relayIndex {
            return false
        }

        mcpServers[serverName] = [
            "type": "stdio",
            "command": "node",
            "args": [relayIndex],
            "env": ["CREDENTIAL_PROXY_APP_URL": "http://127.0.0.1:11111"]
        ] as [String: Any]

        config["mcpServers"] = mcpServers

        guard let jsonData = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]) else {
            return false
        }

        do {
            try jsonData.write(to: URL(fileURLWithPath: claudeJsonPath), options: .atomic)
            NSLog("[MCP] registered credential-proxy in \(claudeJsonPath)")
            return true
        } catch {
            NSLog("[MCP] failed to write \(claudeJsonPath): \(error)")
            return false
        }
    }
}
