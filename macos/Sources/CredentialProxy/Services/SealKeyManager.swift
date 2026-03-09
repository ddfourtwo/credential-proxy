import Foundation
import CryptoKit
import CommonCrypto

/// Manages a "seal key" derived from a user PIN + persistent salt.
///
/// Secrets are encrypted with the seal key (AES-256-GCM). The seal key is
/// never stored — it's derived at each app launch from the user's PIN.
/// An agent cannot derive the key without knowing the PIN.
///
/// Files stored in data dir:
///   - seal.salt: random 32-byte salt (not secret — useless without PIN)
///   - seal.verify: encrypted known string to verify correct PIN
final class SealKeyManager {
    static let shared = SealKeyManager()

    private let dataDir: String = {
        let dir = NSHomeDirectory() + "/Library/Application Support/credential-proxy"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var saltPath: String { dataDir + "/seal.salt" }
    private var verifyPath: String { dataDir + "/seal.verify" }

    private let verificationPlaintext = "credential-proxy-seal-key-valid"
    private let pbkdf2Iterations: UInt32 = 200_000

    private(set) var cachedKey: SymmetricKey?

    var isUnlocked: Bool { cachedKey != nil }
    var isFirstRun: Bool { !FileManager.default.fileExists(atPath: saltPath) }

    private init() {}

    // MARK: - Setup (first run)

    /// Create a new seal key from a user-chosen PIN.
    /// Generates salt, derives key, stores salt + verification blob.
    func setup(pin: String) throws {
        let salt = generateSalt()
        let key = try deriveKey(pin: pin, salt: salt)

        // Encrypt verification string
        let verifyData = try encrypt(verificationPlaintext, key: key)

        // Write salt and verification to files
        try salt.write(to: URL(fileURLWithPath: saltPath))
        try verifyData.write(to: URL(fileURLWithPath: verifyPath))

        // Set restrictive permissions
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: saltPath)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: verifyPath)

        cachedKey = key
    }

    // MARK: - Unlock (subsequent launches)

    /// Unlock with a PIN. Returns true if PIN is correct.
    func unlock(pin: String) throws -> Bool {
        if cachedKey != nil { return true }

        guard let salt = try? Data(contentsOf: URL(fileURLWithPath: saltPath)),
              let verifyData = try? Data(contentsOf: URL(fileURLWithPath: verifyPath)) else {
            throw SealKeyError.noSealData
        }

        let key = try deriveKey(pin: pin, salt: salt)

        // Verify by decrypting the verification blob
        guard let decrypted = try? decrypt(verifyData, key: key),
              decrypted == verificationPlaintext else {
            return false // Wrong PIN
        }

        cachedKey = key
        return true
    }

    // MARK: - Reset

    /// Delete seal data and all encrypted Keychain secrets.
    func reset() {
        try? FileManager.default.removeItem(atPath: saltPath)
        try? FileManager.default.removeItem(atPath: verifyPath)
        cachedKey = nil
        // Delete all stored secrets from Keychain (they can't be decrypted anymore)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.credential-proxy.secrets"
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Key Derivation

    private func generateSalt() -> Data {
        var salt = Data(count: 32)
        salt.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        return salt
    }

    /// Hash the running binary. A rebuilt binary produces a different hash,
    /// so even with the correct PIN, a tampered binary derives a different key.
    private func binaryHash() throws -> Data {
        guard let path = Bundle.main.executablePath else {
            throw SealKeyError.binaryHashFailed
        }
        let binaryData = try Data(contentsOf: URL(fileURLWithPath: path))
        let hash = SHA256.hash(data: binaryData)
        return Data(hash)
    }

    private func deriveKey(pin: String, salt: Data) throws -> SymmetricKey {
        let pinData = Data(pin.utf8)
        // Combine salt with binary hash — ties the key to this exact binary
        let binHash = try binaryHash()
        var combinedSalt = salt
        combinedSalt.append(binHash)
        var derivedKey = Data(count: 32)

        let status = derivedKey.withUnsafeMutableBytes { derivedBytes in
            pinData.withUnsafeBytes { pinBytes in
                combinedSalt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pinBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        pinData.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        combinedSalt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        pbkdf2Iterations,
                        derivedBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        32
                    )
                }
            }
        }

        guard status == kCCSuccess else {
            throw SealKeyError.keyDerivationFailed
        }

        return SymmetricKey(data: derivedKey)
    }

    // MARK: - Encrypt / Decrypt Secrets

    func encrypt(_ plaintext: String) throws -> Data {
        guard let key = cachedKey else {
            throw SealKeyError.notUnlocked
        }
        return try encrypt(plaintext, key: key)
    }

    func decrypt(_ ciphertext: Data) throws -> String {
        guard let key = cachedKey else {
            throw SealKeyError.notUnlocked
        }
        return try decrypt(ciphertext, key: key)
    }

    private func encrypt(_ plaintext: String, key: SymmetricKey) throws -> Data {
        let data = Data(plaintext.utf8)
        let sealedBox = try AES.GCM.seal(data, using: key)
        guard let combined = sealedBox.combined else {
            throw SealKeyError.encryptionFailed
        }
        return combined
    }

    private func decrypt(_ ciphertext: Data, key: SymmetricKey) throws -> String {
        let sealedBox = try AES.GCM.SealedBox(combined: ciphertext)
        let data = try AES.GCM.open(sealedBox, using: key)
        guard let plaintext = String(data: data, encoding: .utf8) else {
            throw SealKeyError.decryptionFailed
        }
        return plaintext
    }
}

enum SealKeyError: LocalizedError {
    case notUnlocked
    case encryptionFailed
    case decryptionFailed
    case keyDerivationFailed
    case noSealData
    case binaryHashFailed

    var errorDescription: String? {
        switch self {
        case .notUnlocked: return "Seal key not unlocked — PIN required"
        case .encryptionFailed: return "Failed to encrypt secret"
        case .decryptionFailed: return "Failed to decrypt secret"
        case .keyDerivationFailed: return "Key derivation failed"
        case .noSealData: return "No seal data found — reinstall required"
        case .binaryHashFailed: return "Could not hash binary — cannot derive seal key"
        }
    }
}
