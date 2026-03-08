import Foundation
import AppKit

@MainActor
final class ServerManager: ObservableObject {
    @Published var isRunning = false
    @Published var statusMessage = "Starting..."

    private var process: Process?
    private let port: Int
    private let mgmtToken: String
    private var healthCheckTimer: Timer?

    var serverPath: String {
        // When running from .app bundle: Contents/Resources/mcp-server/index.js
        if let resourcePath = Bundle.main.resourcePath {
            let bundled = "\(resourcePath)/mcp-server/index.js"
            if FileManager.default.fileExists(atPath: bundled) {
                return bundled
            }
        }
        // Fallback: installed location
        let installed = "\(NSHomeDirectory())/.claude/mcp-servers/credential-proxy/index.js"
        if FileManager.default.fileExists(atPath: installed) {
            return installed
        }
        // Dev fallback: relative to binary
        return ""
    }

    init(port: Int = 8787) {
        self.port = port
        // Generate or load management token
        self.mgmtToken = ServerManager.loadOrCreateToken()
    }

    func start() {
        guard !serverPath.isEmpty else {
            statusMessage = "Server files not found"
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["node", serverPath, "serve", "--port", "\(port)"]
        proc.environment = ProcessInfo.processInfo.environment
        proc.environment?["CREDENTIAL_PROXY_MGMT_TOKEN"] = mgmtToken
        proc.environment?["CREDENTIAL_PROXY_USE_KEYCHAIN"] = "1"

        // Use app support dir for data
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dataDir = appSupport.appendingPathComponent("CredentialProxy").path
        try? FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        proc.environment?["CREDENTIAL_PROXY_DATA_DIR"] = dataDir

        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.isRunning = false
                self?.statusMessage = "Server stopped"
            }
        }

        do {
            try proc.run()
            process = proc
            statusMessage = "Starting server..."

            // Start health check polling
            startHealthChecks()
        } catch {
            statusMessage = "Failed to start: \(error.localizedDescription)"
        }
    }

    func stop() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
        process?.terminate()
        process = nil
        isRunning = false
        statusMessage = "Stopped"
    }

    func restart() {
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.start()
        }
    }

    func getToken() -> String {
        return mgmtToken
    }

    private func startHealthChecks() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let client = APIClient(port: self.port)
                let healthy = await client.healthCheck()
                self.isRunning = healthy
                self.statusMessage = healthy ? "Running on port \(self.port)" : "Starting..."
            }
        }
    }

    private static func loadOrCreateToken() -> String {
        let tokenFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CredentialProxy")
            .appendingPathComponent(".mgmt-token")

        // Try to load existing token
        if let existing = try? String(contentsOf: tokenFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty {
            return existing
        }

        // Generate new token
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()

        // Save it
        let dir = tokenFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? token.write(to: tokenFile, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile.path)

        return token
    }
}
