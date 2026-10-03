import Foundation

/// Full upstream text is the merge base; a commit alone cannot reconstruct offline edits.
struct SkillSourceRevision: Codable, Hashable, Sendable {
    let source: String
    let branch: String
    let path: String
    let revision: String
    let content: String

    var sourceURL: URL? {
        var url = URL(string: "https://github.com")!
        for component in source.split(separator: "/") { url.appendPathComponent(String(component)) }
        url.appendPathComponent("blob")
        url.appendPathComponent(revision)
        for component in path.split(separator: "/") { url.appendPathComponent(String(component)) }
        return url
    }
}
