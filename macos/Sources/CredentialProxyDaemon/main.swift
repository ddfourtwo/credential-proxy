import Foundation
import CredentialProxyCore

// MARK: - Signal Handling

// Ignore SIGTERM default behavior so we can handle it gracefully
signal(SIGTERM, SIG_IGN)

let sigTermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigTermSource.setEventHandler {
    fputs("credential-proxy-daemon: received SIGTERM, shutting down...\n", stderr)
    daemonServerManager?.stop()
    fputs("credential-proxy-daemon: shutdown complete\n", stderr)
    exit(0)
}
sigTermSource.resume()

// MARK: - Key File Loading

let dataDir = NSHomeDirectory() + "/Library/Application Support/credential-proxy"

let keyFilePath: String
if let envPath = ProcessInfo.processInfo.environment["CREDENTIAL_PROXY_KEY_FILE"] {
    keyFilePath = envPath
} else {
    keyFilePath = dataDir + "/daemon.key"
}

let verifyPath = keyFilePath + ".verify"

// Validate key file exists
guard FileManager.default.fileExists(atPath: keyFilePath) else {
    fputs("credential-proxy-daemon: error: key file not found at \(keyFilePath)\n", stderr)
    fputs("credential-proxy-daemon: run 'Enable Daemon Mode' in the GUI app first\n", stderr)
    exit(1)
}

// Load the key
do {
    try SealKeyManager.shared.unlockWithKeyFile(path: keyFilePath)
} catch {
    fputs("credential-proxy-daemon: error: failed to load key file: \(error.localizedDescription)\n", stderr)
    exit(1)
}

// Validate with verification file
if FileManager.default.fileExists(atPath: verifyPath) {
    do {
        let verifyData = try Data(contentsOf: URL(fileURLWithPath: verifyPath))
        let plaintext = try SealKeyManager.shared.decrypt(verifyData)
        guard plaintext == "credential-proxy-seal-key-valid" else {
            fputs("credential-proxy-daemon: error: key file verification failed — key does not match\n", stderr)
            exit(1)
        }
    } catch {
        fputs("credential-proxy-daemon: error: key file verification failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
} else {
    fputs("credential-proxy-daemon: warning: verification file not found at \(verifyPath), skipping verification\n", stderr)
}

// MARK: - Start Server

var daemonServerManager: DaemonServerManager? = DaemonServerManager()

do {
    try daemonServerManager?.start()
    fputs("credential-proxy-daemon: started on port 11111\n", stderr)
} catch {
    fputs("credential-proxy-daemon: error: failed to start server: \(error.localizedDescription)\n", stderr)
    exit(1)
}

// Keep process alive
dispatchMain()
