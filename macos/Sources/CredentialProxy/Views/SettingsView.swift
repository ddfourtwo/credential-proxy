import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var serverManager: ServerManager

    var body: some View {
        Form {
            Section("Server") {
                LabeledContent("Status") {
                    HStack {
                        Circle()
                            .fill(serverManager.isRunning ? .green : .red)
                            .frame(width: 8, height: 8)
                        Text(serverManager.statusMessage)
                    }
                }

                HStack {
                    Button("Restart Server") {
                        serverManager.restart()
                    }
                    Button(serverManager.isRunning ? "Stop" : "Start") {
                        if serverManager.isRunning {
                            serverManager.stop()
                        } else {
                            serverManager.start()
                        }
                    }
                }
            }

            Section("About") {
                LabeledContent("Version", value: "1.0.0")
                LabeledContent("Server", value: "Native (port 8787)")
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 250)
    }
}
