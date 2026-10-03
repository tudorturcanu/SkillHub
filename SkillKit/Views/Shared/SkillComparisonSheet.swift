import SwiftUI

/// Two items' text, shown side by side by the Compare action.
struct SkillComparison: Identifiable {
    let id = UUID()
    let leftName: String
    let left: String
    let rightName: String
    let right: String
}

extension SkillComparison {
    /// Compares what is on disk now, falling back to the indexed text for
    /// remote items or a file that can't be read.
    @MainActor
    init(_ left: Skill, _ right: Skill) {
        func text(_ skill: Skill) -> String {
            skill.isRemote ? skill.content : (SkillEditorDocument.readLocalFile(at: skill.filePath) ?? skill.content)
        }
        self.init(leftName: left.name, left: text(left), rightName: right.name, right: text(right))
    }
}

struct SkillComparisonSheet: View {
    let comparison: SkillComparison
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(comparison.leftName, systemImage: "minus.circle").foregroundStyle(.red)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                Label(comparison.rightName, systemImage: "plus.circle").foregroundStyle(.green)
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.cancelAction)
            }
            .font(.callout)
            .lineLimit(1)
            .padding(10)
            Divider()
            DiffReviewPanel(
                original: comparison.left,
                proposed: comparison.right,
                onAccept: nil,
                onReject: nil,
                title: "Compare"
            )
        }
        .frame(minWidth: 640, idealWidth: 820, minHeight: 440, idealHeight: 620)
    }
}
