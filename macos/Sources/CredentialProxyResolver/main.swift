import Foundation
import Security

// credential-proxy-resolve: reads a secret from macOS Keychain
// Usage: credential-proxy-resolve <SECRET_NAME>
// Outputs the decrypted value to stdout (no trailing newline)
// Exit codes: 0 = success, 1 = not found, 2 = error

let service = "com.credential-proxy.secrets"

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: credential-proxy-resolve <SECRET_NAME>\n", stderr)
    exit(2)
}

let name = CommandLine.arguments[1]

let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service,
    kSecAttrAccount as String: name,
    kSecReturnData as String: true,
    kSecMatchLimit as String: kSecMatchLimitOne
]

var result: AnyObject?
let status = SecItemCopyMatching(query as CFDictionary, &result)

if status == errSecItemNotFound {
    fputs("Secret not found: \(name)\n", stderr)
    exit(1)
}

guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
    fputs("Keychain error: \(status)\n", stderr)
    exit(2)
}

// Output value to stdout without trailing newline
print(value, terminator: "")
