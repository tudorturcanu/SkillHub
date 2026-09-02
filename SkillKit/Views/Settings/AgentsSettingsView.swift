import SwiftUI
import AppKit

/// Settings pane for the coding agents that drive the compose panel: shows where each
/// binary was detected (login-shell PATH, standard locations, or a manual override), lets
/// the user point SkillKit at a specific executable, and mirrors the enable toggles in
/// `AgentConfiguration`.
struct AgentsSettingsView: View {
    @State private var config = AgentConfiguration.shared
    @State private var isRedetecting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Agents")
                .font(.headline)

            Text("The compose panel drives these command-line agents directly. SkillKit looks for each binary on your login shell's PATH first (so fnm, mise, volta, bun and pnpm installs are found), then in ~/.local/bin, Homebrew, /usr/local/bin and nvm. Choose a binary manually if yours lives somewhere else.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                ForEach(config.supported) { agentId in
                    agentRow(agentId)
                    if agentId != config.supported.last {
                        Divider().padding(.leading, 12)
                    }
                }
            }
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))

            HStack(spacing: 8) {
                Button {
                    redetect()
                } label: {
                    Label("Re-detect", systemImage: "arrow.clockwise")
                }
                .disabled(isRedetecting)

                if isRedetecting || !config.detectionComplete {
                    ProgressView().controlSize(.small)
                    Text("Asking your login shell for its PATH…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(20)
        .task {
            await config.refreshDetection()
        }
    }

    @ViewBuilder
    private func agentRow(_ agentId: AgentID) -> some View {
        let resolution = config.binaryResolution(for: agentId)
        let override = config.overridePath(for: agentId)

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: agentId.toolSource.iconName)
                    .font(.title3)
                    .foregroundStyle(agentId.toolSource.color)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 3) {
                    Text(agentId.displayName)
                        .font(.callout.weight(.medium))
                    Text(agentId.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    detectionStatus(agentId: agentId, resolution: resolution, override: override)
                }

                Spacer(minLength: 12)

                Toggle("Enabled", isOn: Binding(
                    get: { config.isEnabled(agentId) },
                    set: { config.setEnabled(agentId, $0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .help(config.isEnabled(agentId) ? "Hide \(agentId.displayName) from the compose panel" : "Show \(agentId.displayName) in the compose panel")
            }

            HStack(spacing: 8) {
                Button("Choose binary…") {
                    if let url = AgentBinaryChooser.choose(for: agentId) {
                        config.setOverride(url, for: agentId)
                    }
                }
                .controlSize(.small)

                if override != nil {
                    Button("Clear") {
                        config.setOverride(nil, for: agentId)
                    }
                    .controlSize(.small)
                    .help("Go back to automatic detection")
                }

                if resolution == nil, override == nil {
                    Link(destination: agentId.installURL) {
                        Label("Install \(agentId.displayName)", systemImage: "arrow.down.circle")
                    }
                    .controlSize(.small)
                }
                Spacer()
            }
            .padding(.leading, 34)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func detectionStatus(agentId: AgentID, resolution: AgentBinaryResolver.Resolution?, override: String?) -> some View {
        if let resolution {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(resolution.url.path)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text("· \(resolution.source.rawValue)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        } else if let override {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(override)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("· chosen binary is missing or not executable")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            .padding(.top, 2)
        } else if !config.detectionComplete {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Looking for \(agentId.displayName)…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        } else {
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.secondary)
                Text("Not found on PATH")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        }
    }

    private func redetect() {
        isRedetecting = true
        Task {
            await config.refreshDetection()
            isRedetecting = false
        }
    }
}

/// Presents an open panel for picking an agent executable. Shared by the Settings pane and
/// the compose panel's "not found" state. Returns nil when cancelled or when the chosen
/// file isn't executable (after telling the user why).
@MainActor
enum AgentBinaryChooser {
    static func choose(for agentId: AgentID) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose \(agentId.displayName) binary"
        panel.message = "Select the `\(agentId.toolSource.cliBinaryName ?? agentId.rawValue)` executable SkillKit should run."
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.resolvesAliases = true

        let config = AgentConfiguration.shared
        if let current = config.overridePath(for: agentId) ?? config.binaryURL(for: agentId)?.path {
            panel.directoryURL = URL(fileURLWithPath: current).deletingLastPathComponent()
        } else {
            panel.directoryURL = URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)
        }

        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Not an executable"
            alert.informativeText = "\(url.lastPathComponent) can't be run as \(agentId.displayName). Pick the `\(agentId.toolSource.cliBinaryName ?? agentId.rawValue)` command itself (for example the file `which \(agentId.toolSource.cliBinaryName ?? agentId.rawValue)` prints in Terminal)."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return nil
        }
        return url
    }
}

#Preview {
    AgentsSettingsView()
        .frame(width: 680)
}
