import SwiftUI

@main
struct CredentialProxyApp: App {
    @StateObject private var serverManager = ServerManager()
    @StateObject private var apiClient = APIClient()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(serverManager)
                .environmentObject(apiClient)
        } label: {
            Image(systemName: serverManager.isRunning ? "key.fill" : "key")
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

    init() {}
}
