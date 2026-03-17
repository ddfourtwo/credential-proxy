// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CredentialProxy",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "CredentialProxyCore",
            path: "Sources/CredentialProxyCore"
        ),
        .executableTarget(
            name: "CredentialProxy",
            dependencies: ["CredentialProxyCore"],
            path: "Sources/CredentialProxy"
        ),
        .executableTarget(
            name: "CredentialProxyDaemon",
            dependencies: ["CredentialProxyCore"],
            path: "Sources/CredentialProxyDaemon"
        ),
    ]
)
