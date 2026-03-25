import SwiftUI
import LocalAuthentication
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
                    // Post-unlock setup: daemon export may change the key
                    // (migrateToSharedKey), so it must run BEFORE signing.
                    Task {
                        // Auto-enable daemon mode (may migrate key format)
                        if !SealKeyManager.shared.daemonKeyExists {
                            _ = try? SealKeyManager.shared.exportKeyForDaemon()
                        }
                        // Sign metadata if signature is missing (requires system auth)
                        await Self.signMetadataIfNeeded()
                        // Start server after everything is signed and ready
                        await MainActor.run {
                            ServerManager.startShared()
                        }
                    }
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

    // MARK: - Metadata Signing

    /// If secrets.json exists but has no HMAC signature, prompt for
    /// Touch ID / system password before signing. This prevents an agent
    /// from tampering with the file and getting it silently re-signed.
    static func signMetadataIfNeeded() async {
        guard await SecretStore.shared.needsSignature else { return }

        let context = LAContext()
        context.localizedReason = "sign credential metadata"

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            NSLog("[Sign] authentication not available: \(error?.localizedDescription ?? "unknown")")
            return
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Credential Proxy needs to sign its metadata file. This is a one-time operation after an update."
            ) { success, authError in
                if success {
                    Task {
                        do {
                            try await SecretStore.shared.resignMetadata()
                            NSLog("[Sign] metadata signed after user authentication")
                        } catch {
                            NSLog("[Sign] failed to sign: \(error)")
                        }
                    }
                } else {
                    NSLog("[Sign] user declined authentication: \(authError?.localizedDescription ?? "cancelled")")
                }
                continuation.resume()
            }
        }
    }

    // MARK: - MCP Auto-Registration

    private static let appPort = 11111

    /// Register credential-proxy as an MCP server in config files if not already present.
    /// Returns true if any registration was performed (first launch or path changed).
    static func registerMCPIfNeeded() -> Bool {
        guard let bundlePath = Bundle.main.resourcePath else { return false }
        let relayIndex = bundlePath + "/mcp-relay/index.js"

        guard FileManager.default.fileExists(atPath: relayIndex) else {
            NSLog("[MCP] relay not found at \(relayIndex)")
            return false
        }

        let baseEntry: [String: Any] = [
            "type": "stdio",
            "command": "node",
            "args": [relayIndex],
            "env": ["CREDENTIAL_PROXY_APP_URL": "http://127.0.0.1:\(appPort)"]
        ]

        var registered = false

        // Claude Code (~/.claude.json)
        if registerInConfig(
            path: NSHomeDirectory() + "/.claude.json",
            relayIndex: relayIndex,
            entry: baseEntry
        ) { registered = true }

        // Pi MCP adapter (~/.pi/agent/mcp.json)
        let piDir = NSHomeDirectory() + "/.pi/agent"
        let piConfig = piDir + "/mcp.json"
        if FileManager.default.fileExists(atPath: piDir) || FileManager.default.fileExists(atPath: piConfig) {
            var piEntry = baseEntry
            piEntry["lifecycle"] = "keep-alive"
            piEntry["directTools"] = true
            if registerInConfig(
                path: piConfig,
                relayIndex: relayIndex,
                entry: piEntry
            ) { registered = true }
        }

        return registered
    }

    /// Register credential-proxy in a single MCP config file.
    /// Preserves existing keys (like lifecycle) while updating command/args/env.
    private static func registerInConfig(path: String, relayIndex: String, entry: [String: Any]) -> Bool {
        // Ensure parent directory exists
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        var config: [String: Any]
        if let data = FileManager.default.contents(atPath: path),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            config = parsed
        } else {
            config = [:]
        }

        let key = config["mcp-servers"] != nil && config["mcpServers"] == nil ? "mcp-servers" : "mcpServers"
        var mcpServers = config[key] as? [String: Any] ?? [:]

        // Already registered with correct path and port — skip
        if let existing = mcpServers["credential-proxy"] as? [String: Any],
           let args = existing["args"] as? [String], args.first == relayIndex,
           let env = existing["env"] as? [String: String],
           env["CREDENTIAL_PROXY_APP_URL"]?.contains("\(appPort)") == true {
            return false
        }

        // Merge: preserve existing fields (lifecycle, directTools), update command/args/env
        var merged = mcpServers["credential-proxy"] as? [String: Any] ?? [:]
        for (k, v) in entry { merged[k] = v }
        mcpServers["credential-proxy"] = merged

        config[key] = mcpServers

        guard let jsonData = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]) else {
            return false
        }

        do {
            try jsonData.write(to: URL(fileURLWithPath: path), options: .atomic)
            NSLog("[MCP] registered credential-proxy in \(path)")
            return true
        } catch {
            NSLog("[MCP] failed to write \(path): \(error)")
            return false
        }
    }
}
