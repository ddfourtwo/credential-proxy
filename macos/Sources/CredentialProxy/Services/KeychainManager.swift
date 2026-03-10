import Foundation

/// Manages credential storage as encrypted files.
/// Each secret is stored as an AES-256-GCM encrypted file:
///   - Location: ~/Library/Application Support/credential-proxy/secrets/{name}.sealed
///   - Encrypted with the seal key via SealKeyManager
///
/// Previously used macOS Keychain, but per-application ACL restrictions
/// caused password prompts on every binary rebuild. File-based storage
/// avoids this entirely — security is provided by seal key encryption.
final class KeychainManager {
    static let shared = KeychainManager()
    private let service = "com.credential-proxy.secrets"

    private let secretsDir: String = {
        let dir = NSHomeDirectory() + "/Library/Application Support/credential-proxy/secrets"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }()

    private init() {}

    private func pathFor(name: String) -> String {
        secretsDir + "/" + name + ".sealed"
    }

    func store(name: String, value: String) throws {
        let encrypted = try SealKeyManager.shared.encrypt(value)
        let path = pathFor(name: name)
        try encrypted.write(to: URL(fileURLWithPath: path), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    func retrieve(name: String) throws -> String? {
        let path = pathFor(name: name)
        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try SealKeyManager.shared.decrypt(data)
    }

    func delete(name: String) throws {
        let path = pathFor(name: name)
        if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }
    }

    func list() throws -> [String] {
        guard FileManager.default.fileExists(atPath: secretsDir) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(atPath: secretsDir)
        return files
            .filter { $0.hasSuffix(".sealed") }
            .map { String($0.dropLast(7)) } // remove ".sealed"
    }
}

enum KeychainError: LocalizedError {
    case encodingFailed
    case storeFailed(OSStatus)
    case retrieveFailed(OSStatus)
    case deleteFailed(OSStatus)
    case listFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodingFailed: return "Failed to encode secret value"
        case .storeFailed(let s): return "Keychain store failed: \(s)"
        case .retrieveFailed(let s): return "Keychain retrieve failed: \(s)"
        case .deleteFailed(let s): return "Keychain delete failed: \(s)"
        case .listFailed(let s): return "Keychain list failed: \(s)"
        }
    }
}
