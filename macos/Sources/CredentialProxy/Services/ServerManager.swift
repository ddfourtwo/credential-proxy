import Foundation
import AppKit
import Security

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
        return ""
    }

    private var resolverPath: String? {
        if let resourcePath = Bundle.main.resourcePath {
            let path = "\(resourcePath)/credential-proxy-resolve"
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    init(port: Int = 8787) {
        self.port = port
        self.mgmtToken = ServerManager.loadOrCreateKeychainToken()
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
        proc.environment?["CREDENTIAL_PROXY_KEYCHAIN"] = "1"

        // Point resolver to the bundled binary
        if let resolver = resolverPath {
            proc.environment?["CREDENTIAL_PROXY_RESOLVER_PATH"] = resolver
        }

        // Use app support dir for metadata
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

    // MARK: - Keychain-based token storage

    private static let tokenService = "com.credential-proxy.mgmt-token"
    private static let tokenAccount = "management"

    private static func loadOrCreateKeychainToken() -> String {
        // Try to load from Keychain
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: tokenService,
            kSecAttrAccount as String: tokenAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess, let data = result as? Data, let token = String(data: data, encoding: .utf8), !token.isEmpty {
            return token
        }

        // Generate new token
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()

        // Store in Keychain
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: tokenService,
            kSecAttrAccount as String: tokenAccount,
            kSecValueData as String: token.data(using: .utf8)!,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrLabel as String: "Credential Proxy: Management Token"
        ]
        SecItemAdd(addQuery as CFDictionary, nil)

        // Remove old file-based token if it exists
        let oldTokenFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CredentialProxy")
            .appendingPathComponent(".mgmt-token")
        try? FileManager.default.removeItem(at: oldTokenFile)

        return token
    }
}
