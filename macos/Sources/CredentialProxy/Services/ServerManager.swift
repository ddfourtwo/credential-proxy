import Foundation
import AppKit
import Security

@MainActor
final class ServerManager: ObservableObject {
    @Published var isRunning = false
    @Published var statusMessage = "Starting..."

    private var httpServer: HTTPServer?
    private let port: UInt16
    private let mgmtToken: String
    private var healthCheckTimer: Timer?

    init(port: UInt16 = 8787) {
        self.port = port
        self.mgmtToken = ServerManager.loadOrCreateKeychainToken()
    }

    func start() {
        let server = HTTPServer(port: port)

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dataDir = appSupport.appendingPathComponent("credential-proxy").path
        try? FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let auditLogger = AuditLogger(logFilePath: "\(dataDir)/audit.log")
        let secretStore = SecretStore.shared
        let router = Router()

        RequestHandler.configureRoutes(
            router: router,
            secretStore: secretStore,
            auditLogger: auditLogger,
            mgmtToken: mgmtToken
        )

        do {
            try server.start(router: router)
            httpServer = server
            statusMessage = "Starting server..."
            startHealthChecks()
        } catch {
            statusMessage = "Failed to start: \(error.localizedDescription)"
        }
    }

    func stop() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
        httpServer?.stop()
        httpServer = nil
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
                let client = APIClient(port: Int(self.port))
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
