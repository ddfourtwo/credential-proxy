// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CredentialProxy",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "CredentialProxy",
            path: "Sources/CredentialProxy"
        ),
        .executableTarget(
            name: "credential-proxy-resolve",
            path: "Sources/CredentialProxyResolver"
        )
    ]
)
