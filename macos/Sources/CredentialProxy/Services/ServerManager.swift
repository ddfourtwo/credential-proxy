import Foundation
import AppKit
import Security
import CredentialProxyCore

final class ServerManager: ObservableObject {
    static let shared = ServerManager()

    @Published var isRunning = false
    @Published var statusMessage = "Starting..."
    @Published var isDaemonMode = false

    private var httpServer: HTTPServer?
    let port: UInt16
    private var mgmtToken: String
    private var healthCheckTimer: Timer?

    init(port: UInt16 = 11111) {
        self.port = port
        // Generate ephemeral token in memory — never written to disk.
        // Management endpoints are only used by the in-process UI.
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        self.mgmtToken = bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func startShared() {
        guard shared.httpServer == nil else { return }
        shared.start()
    }

    func start() {
        NSLog("[ServerManager] start() called, port=\(port)")

        // Check if daemon is already running on our port
        if checkDaemonRunning() {
            NSLog("[ServerManager] daemon detected on port \(port), entering management client mode")
            isDaemonMode = true
            loadDaemonMgmtToken()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isRunning = true
                self.statusMessage = "Daemon mode (port \(self.port))"
            }
            startHealthChecks()
            return
        }

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
            mgmtToken: mgmtToken,
            requestCredentialHandler: { request in
                guard let body = request.body, !body.isEmpty else {
                    return .error(400, "Request body is required")
                }

                struct RequestCredentialBody: Codable {
                    let name: String?
                    let domains: [String]?
                    let placements: [String]?
                    let commands: [String]?
                    let allowedDomains: [String]?
                    let allowedPlacements: [String]?
                    let allowedCommands: [String]?
                    var resolvedDomains: [String]? { domains ?? allowedDomains }
                    var resolvedPlacements: [String]? { placements ?? allowedPlacements }
                    var resolvedCommands: [String]? { commands ?? allowedCommands }
                }

                let parsed: RequestCredentialBody
                do {
                    parsed = try JSONDecoder().decode(RequestCredentialBody.self, from: body)
                } catch {
                    return .error(400, "Invalid JSON")
                }

                guard let name = parsed.name, !name.isEmpty else {
                    return .error(400, "name is required")
                }

                guard let domains = parsed.resolvedDomains, !domains.isEmpty else {
                    return .error(400, "domains is required and must not be empty")
                }

                let placements = parsed.resolvedPlacements ?? ["header"]

                let saved = await CredentialRequestManager.shared.requestCredential(
                    name: name.uppercased(),
                    domains: domains,
                    placements: placements,
                    commands: parsed.resolvedCommands
                )

                if saved {
                    return .json(200, ["success": AnyCodableValue.bool(true)])
                } else {
                    return .json(200, ["cancelled": AnyCodableValue.bool(true)])
                }
            },
            updateCredentialHandler: { request in
                guard let body = request.body, !body.isEmpty else {
                    return .error(400, "Request body is required")
                }

                struct UpdateCredentialBody: Codable {
                    let name: String?
                    let domains: [String]?
                    let placements: [String]?
                    let commands: [String]?
                    let allowedDomains: [String]?
                    let allowedPlacements: [String]?
                    let allowedCommands: [String]?
                    var resolvedDomains: [String]? { domains ?? allowedDomains }
                    var resolvedPlacements: [String]? { placements ?? allowedPlacements }
                    var resolvedCommands: [String]? { commands ?? allowedCommands }
                }

                let parsed: UpdateCredentialBody
                do {
                    parsed = try JSONDecoder().decode(UpdateCredentialBody.self, from: body)
                } catch {
                    return .error(400, "Invalid JSON")
                }

                guard let name = parsed.name, !name.isEmpty else {
                    return .error(400, "name is required")
                }

                // Look up current metadata
                guard let meta = try? await secretStore.getSecretMetadata(name: name) else {
                    return .error(404, "Credential '\(name)' not found")
                }

                let approved = await CredentialRequestManager.shared.updateCredential(
                    name: name,
                    currentDomains: meta.allowedDomains,
                    currentPlacements: meta.allowedPlacements.map(\.rawValue),
                    currentCommands: meta.allowedCommands,
                    proposedDomains: parsed.resolvedDomains,
                    proposedPlacements: parsed.resolvedPlacements,
                    proposedCommands: parsed.resolvedCommands
                )

                if approved {
                    return .json(200, ["success": AnyCodableValue.bool(true)])
                } else {
                    return .json(200, ["denied": AnyCodableValue.bool(true)])
                }
            }
        )

        do {
            try server.start(router: router)
            httpServer = server
            DispatchQueue.main.async { [weak self] in
                self?.statusMessage = "Starting server..."
            }
            NSLog("[ServerManager] server.start() succeeded")
            startHealthChecks()
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.statusMessage = "Failed to start: \(error.localizedDescription)"
            }
            NSLog("[ServerManager] server.start() failed: \(error)")
        }
    }

    func stop() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
        httpServer?.stop()
        httpServer = nil
        DispatchQueue.main.async { [weak self] in
            self?.isRunning = false
            self?.statusMessage = "Stopped"
        }
    }

    func restart() {
        stop()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.start()
        }
    }

    func getToken() -> String {
        return mgmtToken
    }

    private func checkDaemonRunning() -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var result = false

        let url = URL(string: "http://127.0.0.1:\(port)/health")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 2.0

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            guard error == nil,
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["status"] as? String == "ok" else { return }
            result = true
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 3.0)
        return result
    }

    private func loadDaemonMgmtToken() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let tokenPath = appSupport.appendingPathComponent("credential-proxy/daemon.mgmt-token").path
        if let tokenData = FileManager.default.contents(atPath: tokenPath),
           let token = String(data: tokenData, encoding: .utf8) {
            self.mgmtToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
            NSLog("[ServerManager] loaded daemon mgmt token from file")
        } else {
            NSLog("[ServerManager] warning: could not read daemon mgmt token")
        }
    }

    private func startHealthChecks() {
        let port = self.port
        DispatchQueue.main.async { [weak self] in
            self?.healthCheckTimer?.invalidate()
            self?.healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                Task {
                    guard let self else { return }
                    let client = APIClient(port: Int(port))
                    let healthy = await client.healthCheck()
                    await MainActor.run {
                        self.isRunning = healthy
                        self.statusMessage = healthy ? "Running on port \(port)" : "Starting..."
                    }
                }
            }
        }
    }

}
