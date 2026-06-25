import Foundation
import SwiftUI

// MARK: - Native static security scanner for skills & rules.
//
// This is a clean-room Swift port of the *static* (offline, no-LLM) detection
// stage of NVIDIA's SkillSpector (Apache-2.0). It re-implements the regex- and
// string-detectable signatures only. SkillSpector's AST, taint-tracking, and
// YARA stages require a Python parser/engine and are NOT ported here; the most
// dangerous of those (exec/eval, curl|bash, credential exfil) are approximated
// with high-signal regexes and tagged `.heuristic` so we never over-promise.
//
// Attribution (Apache-2.0 NOTICE): rule taxonomy derived from
// github.com/NVIDIA/SkillSpector. We do not use the NVIDIA or SkillSpector
// names in any user-facing string.

enum SecuritySeverity: String, CaseIterable, Comparable {
    case critical, high, medium, low

    /// Contribution to the 0–100 risk score per matched finding.
    var weight: Int {
        switch self {
        case .critical: 40
        case .high: 20
        case .medium: 8
        case .low: 3
        }
    }

    var label: String {
        switch self {
        case .critical: "Critical"
        case .high: "High"
        case .medium: "Medium"
        case .low: "Low"
        }
    }

    var icon: String {
        switch self {
        case .critical: "exclamationmark.octagon.fill"
        case .high: "exclamationmark.triangle.fill"
        case .medium: "exclamationmark.circle.fill"
        case .low: "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .critical: .red
        case .high: .orange
        case .medium: .yellow
        case .low: .secondary
        }
    }

    private var rank: Int {
        switch self {
        case .critical: 3
        case .high: 2
        case .medium: 1
        case .low: 0
        }
    }

    static func < (lhs: SecuritySeverity, rhs: SecuritySeverity) -> Bool {
        lhs.rank < rhs.rank
    }
}

enum SecurityCategory: String {
    case promptInjection = "Prompt Injection"
    case dataExfiltration = "Data Exfiltration"
    case privilegeEscalation = "Privilege Escalation"
    case supplyChain = "Supply Chain"
    case codeExecution = "Code Execution"
    case credentialAccess = "Credential Access"
    case persistence = "Persistence"
    case obfuscation = "Obfuscation"
    case toolPoisoning = "Tool Poisoning"
}

/// One concrete detection signature.
struct SecurityRule {
    let id: String            // e.g. "SC2", mirrors SkillSpector IDs where applicable
    let category: SecurityCategory
    let severity: SecuritySeverity
    let title: String
    let pattern: NSRegularExpression
    /// `true` when this is a regex approximation of an AST/taint/YARA rule
    /// rather than a faithful static signature.
    let heuristic: Bool

    init(_ id: String,
         _ category: SecurityCategory,
         _ severity: SecuritySeverity,
         _ title: String,
         _ regex: String,
         heuristic: Bool = false) {
        self.id = id
        self.category = category
        self.severity = severity
        self.title = title
        // Patterns are authored to compile; trap loudly in debug if one doesn't.
        self.pattern = try! NSRegularExpression(
            pattern: regex,
            options: [.caseInsensitive]
        )
        self.heuristic = heuristic
    }
}

struct SecurityFinding: Identifiable, Hashable {
    let id = UUID()
    let ruleID: String
    let category: SecurityCategory
    let severity: SecuritySeverity
    let title: String
    let heuristic: Bool
    let lineNumber: Int
    let snippet: String

    static func == (lhs: SecurityFinding, rhs: SecurityFinding) -> Bool {
        lhs.id == rhs.id
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct SecurityScanResult {
    let findings: [SecurityFinding]
    /// 0 (clean) – 100 (severe). Mirrors SkillSpector's risk score.
    let riskScore: Int

    var isClean: Bool { findings.isEmpty }

    /// Highest severity present, for a headline badge.
    var topSeverity: SecuritySeverity? {
        findings.map(\.severity).max()
    }

    var rating: String {
        switch riskScore {
        case 0: "Clean"
        case 1..<25: "Low risk"
        case 25..<50: "Moderate risk"
        case 50..<80: "High risk"
        default: "Severe risk"
        }
    }

    var findingCountText: String {
        "\(findings.count) finding\(findings.count == 1 ? "" : "s")"
    }

    var severityBreakdownText: String {
        let parts = SecuritySeverity.allCases.compactMap { severity -> String? in
            let count = findings.filter { $0.severity == severity }.count
            guard count > 0 else { return nil }
            return "\(count) \(severity.label.lowercased())"
        }
        return parts.joined(separator: ", ")
    }

    var categorySummaryText: String {
        let categories = Array(Set(findings.map(\.category.rawValue))).sorted()
        guard !categories.isEmpty else { return "No risky categories detected" }
        return categories.joined(separator: ", ")
    }

    var primaryConcernText: String {
        guard let finding = findings.sorted(by: { $0.severity > $1.severity }).first else {
            return "No risky patterns detected"
        }
        return "\(finding.title) on line \(finding.lineNumber)"
    }

    var summaryText: String {
        guard !isClean else { return "No risky patterns detected" }
        return "\(findingCountText): \(severityBreakdownText)"
    }

    var rawScore: Int {
        findings.reduce(0) { $0 + $1.severity.weight }
    }

    var scoreBreakdownText: String {
        guard !isClean else { return "No findings, so the score is 0." }

        let parts = SecuritySeverity.allCases.compactMap { severity -> String? in
            let count = findings.filter { $0.severity == severity }.count
            guard count > 0 else { return nil }
            return "\(count) \(severity.label.lowercased()) x \(severity.weight)"
        }

        let formula = parts.joined(separator: " + ")
        if rawScore > riskScore {
            return "\(formula) = \(rawScore), capped at \(riskScore)."
        }
        return "\(formula) = \(riskScore)."
    }

    var scoreReasonText: String {
        guard !isClean else { return "No risky patterns were detected." }
        return "Score is based on severity weights: critical 40, high 20, medium 8, low 3."
    }
}

enum SecurityScanner {

    // MARK: Rules (static, regex-detectable subset of SkillSpector's 64)

    static let rules: [SecurityRule] = [
        // --- Prompt Injection ---
        .init("P1", .promptInjection, .high, "Instruction override",
              #"ignore\s+(all\s+)?(previous|prior|above|earlier)\s+(instructions|prompts|rules)"#),
        .init("P2", .promptInjection, .high, "Safety-constraint bypass",
              #"(disregard|bypass|override)\s+(your\s+)?(safety|security|guard|content)\s*(rails|constraints|guidelines|policies)?"#),
        .init("P6", .promptInjection, .high, "System-prompt extraction",
              #"(reveal|print|repeat|show|leak)\s+(your\s+)?(system\s+prompt|initial\s+instructions|developer\s+message)"#),
        .init("TP1", .toolPoisoning, .high, "Hidden instructions in comment",
              #"<!--[^>]*\b(ignore|system|instruction|secret|exfiltrat|do not)\b[^>]*-->"#),
        .init("TP2", .toolPoisoning, .high, "Zero-width / RTL deception characters",
              #"[\x{200B}\x{200C}\x{200D}\x{202A}-\x{202E}\x{2066}-\x{2069}\x{FEFF}]"#),

        // --- Code Execution (AST approximations) ---
        .init("AST1", .codeExecution, .critical, "Dynamic code execution (exec)",
              #"\bexec\s*\("#, heuristic: true),
        .init("AST2", .codeExecution, .high, "Dynamic evaluation (eval)",
              #"\beval\s*\("#, heuristic: true),
        .init("AST4", .codeExecution, .high, "Subprocess / shell invocation",
              #"\b(subprocess\.(Popen|run|call|check_output)|os\.system|os\.popen)\s*\("#, heuristic: true),
        .init("TM1", .codeExecution, .high, "Unsafe shell parameter",
              #"shell\s*=\s*True"#, heuristic: true),
        .init("AST3", .codeExecution, .high, "Dynamic import",
              #"\b__import__\s*\(|importlib\.import_module\s*\("#, heuristic: true),

        // --- Supply Chain ---
        .init("SC2", .supplyChain, .high, "Remote script piped to shell",
              #"(curl|wget)\b[^\n|]*\|\s*(sudo\s+)?(bash|sh|zsh|python\d?)"#),
        .init("SC2b", .supplyChain, .high, "Remote install one-liner",
              #"(curl|wget|iwr|irm)\b[^\n]*\b(install|setup)\.(sh|py|ps1)"#),

        // --- Obfuscation ---
        .init("SC3", .obfuscation, .high, "Base64-decoded execution",
              #"base64\s+(-d|--decode|-D)|b64decode\s*\(|atob\s*\(|FromBase64String"#, heuristic: true),
        .init("SC3b", .obfuscation, .medium, "Long opaque base64 blob",
              #"[A-Za-z0-9+/]{120,}={0,2}"#),

        // --- Privilege Escalation ---
        .init("PE2", .privilegeEscalation, .medium, "Privileged execution (sudo/root)",
              #"\bsudo\s+\S|chmod\s+\+s|setuid\s*\("#),
        .init("DESTROY", .privilegeEscalation, .high, "Destructive filesystem command",
              #"rm\s+-rf?\s+(/|~|\$HOME|\*)|mkfs\.|dd\s+if=.*of=/dev/"#),

        // --- Credential Access ---
        .init("PE3", .credentialAccess, .high, "Reads SSH keys / credentials",
              #"(\.ssh/(id_rsa|id_ed25519|authorized_keys)|\.aws/credentials|\.netrc|id_rsa\b)"#),
        .init("E2", .credentialAccess, .high, "Harvests environment secrets",
              #"(os\.environ|process\.env|getenv)\b[^\n]{0,40}(KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL)"#),
        .init("CRED", .credentialAccess, .medium, "Hardcoded secret",
              #"(api[_-]?key|secret|password|token)\s*[:=]\s*['"][A-Za-z0-9_\-]{16,}['"]"#),

        // --- Data Exfiltration ---
        .init("E1", .dataExfiltration, .medium, "POST to external endpoint",
              #"(requests\.post|fetch|axios\.post|http\.client|urllib\.request)\b[^\n]*https?://"#, heuristic: true),
        .init("E1b", .dataExfiltration, .high, "Pipes data to remote netcat / curl upload",
              #"(nc|ncat|netcat)\s+[^\n]*\d{2,5}|curl\b[^\n]*(--data|-d|-T|--upload-file)\b[^\n]*https?://"#),

        // --- Persistence ---
        .init("RA2", .persistence, .high, "Installs persistence (cron/launchd/startup)",
              #"(crontab\s+-|/etc/cron|LaunchAgents|LaunchDaemons|\.bashrc|\.zshrc|\.profile|rc\.local)\b"#, heuristic: true),
        .init("RA1", .codeExecution, .critical, "Self-modifying code",
              #"open\s*\(\s*__file__|with\s+open\([^)]*__file__"#, heuristic: true),
    ]

    // MARK: Scan

    /// Scan arbitrary text (a skill's markdown body, an embedded script, etc.).
    static func scan(text: String) -> SecurityScanResult {
        guard !text.isEmpty else {
            return SecurityScanResult(findings: [], riskScore: 0)
        }

        var findings: [SecurityFinding] = []
        let lines = text.components(separatedBy: .newlines)

        for (index, line) in lines.enumerated() {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            for rule in rules where rule.pattern.firstMatch(in: line, range: range) != nil {
                findings.append(
                    SecurityFinding(
                        ruleID: rule.id,
                        category: rule.category,
                        severity: rule.severity,
                        title: rule.title,
                        heuristic: rule.heuristic,
                        lineNumber: index + 1,
                        snippet: String(line.trimmingCharacters(in: .whitespaces).prefix(200))
                    )
                )
            }
        }

        return SecurityScanResult(findings: findings, riskScore: score(for: findings))
    }

    /// Saturating weighted score, capped at 100. A single critical never
    /// fully saturates the bar, so multiple findings still escalate.
    private static func score(for findings: [SecurityFinding]) -> Int {
        let raw = findings.reduce(0) { $0 + $1.severity.weight }
        return min(100, raw)
    }

    // MARK: Report

    /// Builds a shareable Markdown audit of all skills with findings.
    static func report(for skills: [Skill]) -> String {
        let scanned = skills.map { ($0, $0.securityScan) }
        let risky = scanned
            .filter { !$0.1.isClean }
            .sorted { $0.1.riskScore > $1.1.riskScore }

        let date = Date.now.formatted(date: .abbreviated, time: .shortened)
        var out = "# SkillKit Security Report\n\n"
        out += "_Generated \(date)_\n\n"
        out += "Scanned **\(skills.count)** items — **\(risky.count)** with findings.\n"

        if risky.isEmpty {
            out += "\n✅ No risky patterns detected.\n"
            return out
        }

        for (skill, result) in risky {
            out += "\n## \(skill.name) — \(result.rating) (\(result.riskScore))\n\n"
            out += "\(result.scoreBreakdownText) \(result.scoreReasonText)\n\n"
            for finding in result.findings.sorted(by: { $0.severity > $1.severity }) {
                let tag = finding.heuristic ? " _(heuristic)_" : ""
                out += "- **[\(finding.severity.label), +\(finding.severity.weight)]** \(finding.title)\(tag) — \(finding.category.rawValue), line \(finding.lineNumber)\n"
            }
        }

        out += "\n---\n_Static heuristic scan. Flags risky patterns, not a guarantee — review skills from untrusted sources yourself._\n"
        return out
    }
}
