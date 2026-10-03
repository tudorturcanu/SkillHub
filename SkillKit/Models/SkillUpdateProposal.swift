import Foundation

struct SkillUpdateProposal: Identifiable {
    let id = UUID()
    let filePath: String
    let installed: SkillSourceRevision
    let upstream: SkillSourceRevision
    let local: String
    let merged: String?

    var hasLocalEdits: Bool { local != installed.content }

    init(filePath: String, installed: SkillSourceRevision, upstream: SkillSourceRevision, local: String) {
        self.filePath = filePath
        self.installed = installed
        self.upstream = upstream
        self.local = local
        // Already incorporated manually: accepting only advances the recorded baseline.
        self.merged = local == upstream.content ? local : EditRebase.apply(original: installed.content, proposed: upstream.content, onto: local)
    }
}
