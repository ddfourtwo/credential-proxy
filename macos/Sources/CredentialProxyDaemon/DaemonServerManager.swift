import Foundation
import Security
import CredentialProxyCore

final class DaemonServerManager {
    private var server: HTTPServer?
    let mgmtToken: String
    private let port: UInt16 = 11111
    private let dataDir: String

    init() {
        // Generate ephemeral mgmt token (32 random bytes, hex-encoded)
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        self.mgmtToken = bytes.map { String(format: "%02x", $0) }.joined()

        // Set dataDir = ~/Library/Application Support/credential-proxy
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.dataDir = appSupport.appendingPathComponent("credential-proxy").path
    }

    func start() throws {
        try? FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let httpServer = HTTPServer(port: port)
        let auditLogger = AuditLogger(logFilePath: "\(dataDir)/audit.log")
        let secretStore = SecretStore.shared
        let router = Router()

        // Configure routes without requestCredentialHandler (defaults to nil for 501 headless mode)
        RequestHandler.configureRoutes(
            router: router,
            secretStore: secretStore,
            auditLogger: auditLogger,
            mgmtToken: mgmtToken
        )

        try httpServer.start(router: router)
        self.server = httpServer

        // Write mgmt token to file so the GUI app can read it when operating as management client
        let tokenPath = "\(dataDir)/daemon.mgmt-token"
        FileManager.default.createFile(
            atPath: tokenPath,
            contents: Data(mgmtToken.utf8),
            attributes: [.posixPermissions: 0o600]
        )
    }

    func stop() {
        server?.stop()
        server = nil

        // Delete daemon.mgmt-token file
        let tokenPath = "\(dataDir)/daemon.mgmt-token"
        try? FileManager.default.removeItem(atPath: tokenPath)
    }
}
