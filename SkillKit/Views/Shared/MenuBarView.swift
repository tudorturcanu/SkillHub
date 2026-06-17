import SwiftUI
import SwiftData
import AppKit

struct MenuBarView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Skill.fileModifiedDate, order: .reverse) private var recentSkills: [Skill]

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
            }
            .padding()

            Divider()

            let topSkills = Array(recentSkills.prefix(10))

            if topSkills.isEmpty {
                Text("No skills found.")
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(topSkills) { skill in
                            Button {
                                copyToClipboard(skill)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(skill.displayName)
                                            .font(.body)
                                        Text(skill.skillDescription.isEmpty ? "No description" : skill.skillDescription)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "doc.on.doc")
                                        .foregroundStyle(.secondary)
                                        .font(.caption)
                                }
                                .padding(.vertical, 6)
                                .padding(.horizontal, 12)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .onHover { isHovered in
                                if isHovered {
                                    NSCursor.pointingHand.push()
                                } else {
                                    NSCursor.pop()
                                }
                            }
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
            }
            .padding()
        }
        .frame(width: 320, height: 400)
    }

    private func copyToClipboard(_ skill: Skill) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(skill.content, forType: .string)
    }
}
