import SwiftUI
import CredentialProxyCore

struct CredentialProxyApp: App {
    @ObservedObject private var serverManager = ServerManager.shared
    @StateObject private var apiClient = APIClient()
    @State private var isUnlocked = false

    var body: some Scene {
        MenuBarExtra {
            if !isUnlocked {
                PinEntryView {
                    isUnlocked = true
                    Task {
                        // Sign metadata on first run after upgrade (before any HTTP endpoints load)
                        try? await SecretStore.shared.signIfNeeded()
                    }
                    ServerManager.startShared()
                }
                .padding(4)
            } else {
                MenuBarView()
                    .environmentObject(serverManager)
                    .environmentObject(apiClient)
            }
        } label: {
            Image(systemName: isUnlocked && serverManager.isRunning ? "key.fill" : "key")
        }
        .menuBarExtraStyle(.window)

        Window("Credential Proxy", id: "main") {
            CredentialListView()
                .environmentObject(serverManager)
                .environmentObject(apiClient)
                .frame(minWidth: 600, minHeight: 400)
        }

        Settings {
            SettingsView()
                .environmentObject(serverManager)
        }
    }
}
