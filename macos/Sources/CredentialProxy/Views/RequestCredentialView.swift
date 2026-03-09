import SwiftUI

struct RequestCredentialView: View {
    let name: String
    let initialDomains: [String]
    let initialPlacements: [String]
    let initialCommands: [String]?
    let onComplete: (Bool) -> Void

    @State private var value = ""
    @State private var domainsText: String
    @State private var placements: Set<String>
    @State private var commandsText: String
    @State private var errorMessage: String?
    @State private var isSaving = false

    private let allPlacements = ["header", "body", "query", "env", "arg"]

    init(
        name: String,
        initialDomains: [String],
        initialPlacements: [String],
        initialCommands: [String]?,
        onComplete: @escaping (Bool) -> Void
    ) {
        self.name = name
        self.initialDomains = initialDomains
        self.initialPlacements = initialPlacements
        self.initialCommands = initialCommands
        self.onComplete = onComplete
        _domainsText = State(initialValue: initialDomains.joined(separator: ", "))
        _placements = State(initialValue: Set(initialPlacements.isEmpty ? ["header"] : initialPlacements))
        _commandsText = State(initialValue: initialCommands?.joined(separator: ", ") ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .foregroundStyle(.orange)
                    .font(.title2)
                Text("Claude is requesting a credential")
                    .font(.headline)
            }

            Divider()

            // Name (read-only)
            VStack(alignment: .leading, spacing: 4) {
                Text("Name").font(.caption).foregroundStyle(.secondary)
                Text(name)
                    .font(.system(.body, design: .monospaced))
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(6)
            }

            // Value (user fills this in)
            VStack(alignment: .leading, spacing: 4) {
                Text("Secret Value").font(.caption).foregroundStyle(.secondary)
                SecureField("Paste your secret value here", text: $value)
                    .textFieldStyle(.roundedBorder)
            }

            // Domains (editable)
            VStack(alignment: .leading, spacing: 4) {
                Text("Allowed Domains").font(.caption).foregroundStyle(.secondary)
                TextField("api.github.com, *.example.com", text: $domainsText)
                    .textFieldStyle(.roundedBorder)
                Text("Comma-separated. Use *.domain.com for wildcards.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Placements (editable checkboxes)
            VStack(alignment: .leading, spacing: 4) {
                Text("Allowed Placements").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    ForEach(allPlacements, id: \.self) { placement in
                        Toggle(placement, isOn: Binding(
                            get: { placements.contains(placement) },
                            set: { isOn in
                                if isOn { placements.insert(placement) }
                                else { placements.remove(placement) }
                            }
                        ))
                        .toggleStyle(.checkbox)
                        .font(.caption)
                    }
                }
            }

            // Commands (editable)
            VStack(alignment: .leading, spacing: 4) {
                Text("Allowed Commands (optional)").font(.caption).foregroundStyle(.secondary)
                TextField("git *, npm publish", text: $commandsText)
                    .textFieldStyle(.roundedBorder)
                Text("Comma-separated glob patterns for exec proxy.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let error = errorMessage {
                Text(error).foregroundStyle(.red).font(.caption)
            }

            HStack {
                Spacer()
                Button("Cancel") { onComplete(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid || isSaving)
            }
        }
        .padding()
        .frame(width: 500)
    }

    private var isValid: Bool {
        !value.isEmpty && !domainsText.isEmpty && !placements.isEmpty
    }

    private func save() {
        isSaving = true
        errorMessage = nil

        let domains = domainsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let cmds = commandsText.isEmpty ? nil : commandsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let placementValues = Array(placements).compactMap { SecretPlacement(rawValue: $0) }

        Task {
            do {
                _ = try await SecretStore.shared.addSecret(
                    name: name,
                    value: value,
                    allowedDomains: domains,
                    allowedPlacements: placementValues,
                    allowedCommands: cmds
                )
                onComplete(true)
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}
