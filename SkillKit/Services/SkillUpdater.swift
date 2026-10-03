import Foundation

@MainActor
enum SkillUpdater {
    static func apply(_ proposal: SkillUpdateProposal, resolvedContent: String, to skill: Skill) throws {
        guard !skill.isDeleted, !skill.isReadOnly, !skill.isRemote, skill.filePath == proposal.filePath else {
            throw UpdateError.staleReview
        }
        let result: Result<Void, Error> = SandboxBookmarkManager.resolveAndAccess(path: SkillEditorDocument.accessRoot(for: skill.filePath)) { _ in
            Result {
                guard try SkillSourceStore.load(for: skill.filePath) == proposal.installed,
                      try String(contentsOfFile: skill.filePath, encoding: .utf8) == proposal.local else {
                    throw UpdateError.staleReview
                }
                try SkillVersionHistory.recordRequiredSnapshot(for: skill, content: proposal.local, reason: "Before upstream update to \(proposal.upstream.revision.prefix(8))")
                let target = URL(fileURLWithPath: skill.filePath).resolvingSymlinksInPath()
                try resolvedContent.write(to: target, atomically: true, encoding: .utf8)
                // Update the index even if provenance cannot be saved, so the UI reflects
                // the successful file write and can offer rollback from version history.
                let parsed = FrontmatterParser.parse(resolvedContent)
                if !parsed.name.isEmpty { skill.name = parsed.name }
                skill.skillDescription = parsed.description
                skill.content = parsed.content
                skill.frontmatter = parsed.frontmatter
                let attributes = try? FileManager.default.attributesOfItem(atPath: target.path)
                skill.fileModifiedDate = (attributes?[.modificationDate] as? Date) ?? .now
                skill.fileSize = resolvedContent.utf8.count
                do {
                    try SkillSourceStore.save(proposal.upstream, for: skill.filePath)
                } catch {
                    throw UpdateError.trackingFailed(error.localizedDescription)
                }
            }
        }
        try result.get()
    }

    enum UpdateError: LocalizedError {
        case staleReview
        case unsavedChanges
        case trackingFailed(String)

        var errorDescription: String? {
            switch self {
            case .staleReview:
                "This file or its source changed after review. Close this review and check for updates again. No update was applied."
            case .unsavedChanges:
                "Save or resolve your editor changes before checking or applying an update."
            case .trackingFailed(let message):
                "The file was updated and its previous version is in History, but source tracking could not be saved: \(message)"
            }
        }
    }
}
