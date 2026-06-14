import Foundation

extension Skill {
    /// Fast, in-memory security scan of the skill's markdown body.
    /// Cheap enough to call from a list row or the dashboard.
    var securityScan: SecurityScanResult {
        SecurityScanner.scan(text: content)
    }

    var hasSecurityRisk: Bool {
        securityScan.findings.contains { $0.severity >= .high }
    }

    /// Deep scan that also reads code files bundled alongside a directory
    /// skill (scripts/, *.py, *.sh, *.js…). Requires sandbox access to the
    /// skill's parent folder, so it goes through SandboxBookmarkManager and
    /// is intended for an explicit "Scan" action, not passive list rendering.
    func deepSecurityScan() -> SecurityScanResult {
        var combined = content

        if isDirectory, !isRemote {
            let dir = (filePath as NSString).deletingLastPathComponent
            let scannable: Set<String> = ["py", "sh", "zsh", "bash", "js", "mjs", "ts", "rb", "pl", "ps1", "txt", "md", "json", "yaml", "yml"]

            SandboxBookmarkManager.resolveAndAccessParent(for: filePath) { _ in
                let fm = FileManager.default
                guard let walker = fm.enumerator(
                    at: URL(fileURLWithPath: dir),
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ) else { return }

                for case let url as URL in walker {
                    guard scannable.contains(url.pathExtension.lowercased()),
                          let data = try? Data(contentsOf: url),
                          data.count < 2_000_000, // skip large/binary blobs
                          let body = String(data: data, encoding: .utf8)
                    else { continue }
                    combined += "\n" + body
                }
            }
        }

        return SecurityScanner.scan(text: combined)
    }
}
