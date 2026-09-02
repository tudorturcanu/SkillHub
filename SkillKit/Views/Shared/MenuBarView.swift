import SwiftUI
import SwiftData
import AppKit

struct MenuBarView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @Query(sort: \Skill.name) private var allSkills: [Skill]
    @State private var copiedSkillID: PersistentIdentifier?
    @State private var copiedResetTask: Task<Void, Never>?

    /// Most recently opened items first; items never opened fall to the end (by name).
    private var recentSkills: [Skill] {
        let opened = allSkills
            .filter { $0.lastOpened != nil }
            .sorted { ($0.lastOpened ?? .distantPast) > ($1.lastOpened ?? .distantPast) }
        let neverOpened = allSkills.filter { $0.lastOpened == nil }
        return Array((opened + neverOpened).prefix(10))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recent Skills")
                    .font(.headline)
                Spacer()
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.plain)
                .help("Open SkillKit")
                .accessibilityLabel("Open SkillKit")
            }
            .padding()

            Divider()

            let topSkills = recentSkills

            if topSkills.isEmpty {
                Text("No skills found.")
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(topSkills, id: \.persistentModelID) { skill in
                            recentRow(skill)
                            Divider()
                        }
                    }
                    .padding(.vertical, 8)
                }
            }

            Divider()

            HStack {
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                Spacer()
                SettingsLink {
                    Text("Settings…")
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded {
                    NSApp.activate(ignoringOtherApps: true)
                })
                .help("Open SkillKit settings")
            }
            .padding()
        }
        .frame(width: 320, height: 400)
    }

    @ViewBuilder
    private func recentRow(_ skill: Skill) -> some View {
        let isCopied = copiedSkillID == skill.persistentModelID
        HStack(spacing: 8) {
            Button {
                copyToClipboard(skill)
            } label: {
                HStack {
                    VStack(alignment: .leading) {
                        Text(skill.name)
                            .font(.body)
                        Text(skill.skillDescription.isEmpty ? "No description" : skill.skillDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if isCopied {
                        Label("Copied", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .transition(.opacity)
                    } else {
                        Image(systemName: "doc.on.doc")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isCopied ? "Copied to clipboard" : "Copy \(skill.name) to clipboard")
            .accessibilityLabel("Copy \(skill.name) to clipboard")
            .accessibilityValue(isCopied ? "Copied" : "")
            .onHover { isHovered in
                if isHovered {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }

            Button {
                openInSkillKit(skill)
            } label: {
                Image(systemName: "arrow.up.forward.square")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .help("Open in SkillKit")
            .accessibilityLabel("Open \(skill.name) in SkillKit")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .animation(.easeInOut(duration: 0.15), value: isCopied)
    }

    private func copyToClipboard(_ skill: Skill) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(skill.content, forType: .string)

        copiedResetTask?.cancel()
        copiedSkillID = skill.persistentModelID
        copiedResetTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            copiedSkillID = nil
        }
    }

    private func openInSkillKit(_ skill: Skill) {
        appState.sidebarFilter = skill.itemKind == .rule ? .allRules : .allSkills
        appState.selectedSkill = skill
        NSApp.activate(ignoringOtherApps: true)
    }
}
