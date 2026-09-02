import SwiftUI
import SwiftData

/// Manage the SSH profiles used by the remote-skills scanner.
struct ServersSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RemoteServer.label) private var servers: [RemoteServer]
    @State private var editingServer: RemoteServer?
    @State private var serverPendingDeletion: RemoteServer?
    @State private var showingEditor = false
    @State private var testingIDs: Set<String> = []
    @State private var statusMessages: [String: ConnectionStatus] = [:]
    @State private var managementError: String?

    enum ConnectionStatus: Equatable {
        case success
        case failure(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Remote Servers")
                .font(.headline)

            Text("Add SSH servers whose SKILL.md files you want SkillKit to sync. Authentication uses your selected key or SSH agent — SkillKit can't prompt for passwords.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if servers.isEmpty {
                ContentUnavailableView(
                    "No Remote Servers",
                    systemImage: "server.rack",
                    description: Text("Add an SSH server to browse and edit its skills here."))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else {
                VStack(spacing: 0) {
                    ForEach(servers) { server in
                        serverRow(server)
                        if server.id != servers.last?.id {
                            Divider().padding(.leading, 12)
                        }
                    }
                }
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                Button {
                    editingServer = nil
                    showingEditor = true
                } label: {
                    Label("Add Server...", systemImage: "plus.circle")
                }
                Spacer()
            }
        }
        .padding()
        .sheet(isPresented: $showingEditor) {
            ServerEditorSheet(server: editingServer) {
                showingEditor = false
            }
        }
        .alert("Remove Remote Server?", isPresented: Binding(
            get: { serverPendingDeletion != nil },
            set: { if !$0 { serverPendingDeletion = nil } }
        ), presenting: serverPendingDeletion) { server in
            Button("Remove", role: .destructive) {
                modelContext.delete(server)
                do {
                    try modelContext.save()
                } catch {
                    managementError = "Could not remove \(server.label): \(error.localizedDescription)"
                }
                serverPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { serverPendingDeletion = nil }
        } message: { server in
            Text("This also removes the \(server.skills.count) synced item\(server.skills.count == 1 ? "" : "s") from SkillKit. Their files remain on the server.")
        }
        .alert("Server Management Error", isPresented: Binding(
            get: { managementError != nil },
            set: { if !$0 { managementError = nil } }
        )) {
            Button("OK", role: .cancel) { managementError = nil }
        } message: {
            Text(managementError ?? "")
        }
    }

    private func serverRow(_ server: RemoteServer) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "server.rack")
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(server.label).font(.body.weight(.semibold))
                Text("\(server.username)@\(server.host):\(server.port) · \(server.skillsBasePath)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                // Prefer a fresh test result; otherwise surface the error persisted by the
                // last sync so users see it without having to press Test.
                if let status = statusMessages[server.id] {
                    statusView(status)
                } else if let syncError = server.lastSyncError {
                    statusView(.failure(syncError), origin: "Last sync failed")
                }
            }
            Spacer()
            Button {
                test(server)
            } label: {
                if testingIDs.contains(server.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "checkmark.icloud")
                }
            }
            .buttonStyle(.plain)
            .disabled(testingIDs.contains(server.id))
            .help("Test SSH connection")
            .accessibilityLabel("Test connection to \(server.label)")
            .accessibilityValue(testingIDs.contains(server.id) ? "Testing" : "")
            Button {
                editingServer = server
                showingEditor = true
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.plain)
            .help("Edit server")
            .accessibilityLabel("Edit \(server.label)")
            Button(role: .destructive) {
                serverPendingDeletion = server
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .help("Remove server")
            .accessibilityLabel("Remove \(server.label)")
        }
        .padding(12)
    }

    @ViewBuilder
    private func statusView(_ status: ConnectionStatus, origin: String? = nil) -> some View {
        switch status {
        case .success:
            Label("Connection successful", systemImage: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.green)
        case .failure(let raw):
            VStack(alignment: .leading, spacing: 4) {
                if SSHService.isAuthenticationFailure(raw) {
                    Label {
                        Text((origin.map { "\($0): " } ?? "") + "Authentication failed")
                    } icon: {
                        Image(systemName: "key.slash")
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.red)
                    Text(SSHService.authenticationGuidance)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    DisclosureGroup("Show raw error") {
                        Text(raw)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                    .font(.caption2)
                } else {
                    Text((origin.map { "\($0): " } ?? "") + raw)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func test(_ server: RemoteServer) {
        testingIDs.insert(server.id)
        statusMessages.removeValue(forKey: server.id)
        Task {
            do {
                try await SSHService.testConnection(server)
                statusMessages[server.id] = .success
            } catch {
                statusMessages[server.id] = .failure(error.localizedDescription)
            }
            testingIDs.remove(server.id)
        }
    }
}

private struct ServerEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let server: RemoteServer?
    let onSaved: () -> Void

    @State private var label = ""
    @State private var host = ""
    @State private var port = 22
    @State private var username = NSUserName()
    @State private var skillsBasePath = "~/.agents/skills"
    @State private var sshKeyPath = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(server == nil ? "Add Remote Server" : "Edit Remote Server")
                .font(.title3.weight(.semibold))
            Form {
                TextField("Label", text: $label)
                TextField("Host", text: $host)
                TextField("Username", text: $username)
                TextField("Port", value: $port, format: .number)
                TextField("Skills directory", text: $skillsBasePath)
                TextField("SSH key path (optional)", text: $sshKeyPath)
                Text("Only key-file or ssh-agent authentication is supported; SkillKit can't enter passwords or passphrases. Leave blank to use your default key or agent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .formStyle(.grouped)
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || skillsBasePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onAppear(perform: load)
    }

    private func load() {
        guard let server else { return }
        label = server.label
        host = server.host
        port = server.port
        username = server.username
        skillsBasePath = server.skillsBasePath
        sshKeyPath = server.sshKeyPath ?? ""
    }

    private func save() {
        guard (1...65_535).contains(port) else {
            errorMessage = "Port must be between 1 and 65535."
            return
        }
        let values = (label.trimmingCharacters(in: .whitespacesAndNewlines), host.trimmingCharacters(in: .whitespacesAndNewlines), username.trimmingCharacters(in: .whitespacesAndNewlines), skillsBasePath.trimmingCharacters(in: .whitespacesAndNewlines))
        let target = server ?? RemoteServer(label: values.0, host: values.1, port: port, username: values.2, skillsBasePath: values.3)
        target.label = values.0
        target.host = values.1
        target.port = port
        target.username = values.2
        target.skillsBasePath = values.3
        target.sshKeyPath = sshKeyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : sshKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if server == nil { modelContext.insert(target) }
        do {
            try modelContext.save()
            onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
