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
    /// Extra check run on a regex hit. Return `false` to drop the match — used
    /// where a regex alone can't express the condition (e.g. "is this `rm -rf`
    /// target actually dangerous?").
    typealias Validator = (_ line: String, _ match: NSTextCheckingResult) -> Bool

    let id: String            // e.g. "SC2", mirrors SkillSpector IDs where applicable
    let category: SecurityCategory
    let severity: SecuritySeverity
    let title: String
    let pattern: NSRegularExpression
    /// `true` when this is a regex approximation of an AST/taint/YARA rule
    /// rather than a faithful static signature.
    let heuristic: Bool
    let validator: Validator?
    /// If any of these rules also match the same line, this rule is dropped
    /// (e.g. plain `sudo` is superseded by `sudo` + destructive command).
    let shadowedBy: Set<String>

    init(_ id: String,
         _ category: SecurityCategory,
         _ severity: SecuritySeverity,
         _ title: String,
         _ regex: String,
         heuristic: Bool = false,
         shadowedBy: Set<String> = [],
         validator: Validator? = nil) {
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
        self.shadowedBy = shadowedBy
        self.validator = validator
    }
}

struct SecurityFinding: Identifiable, Hashable {
    let id = UUID()
    let ruleID: String
    let category: SecurityCategory
    let severity: SecuritySeverity
    let title: String
    let heuristic: Bool
    /// 1-based line in `file` (or in the main skill file when `file` is nil).
    /// Scans run over the full on-disk text, frontmatter included, so this
    /// matches the editor's gutter.
    let lineNumber: Int
    let snippet: String
    /// Skill-relative path of a bundled file (`scripts/run.sh`). `nil` means
    /// the main skill file.
    let file: String?

    init(ruleID: String,
         category: SecurityCategory,
         severity: SecuritySeverity,
         title: String,
         heuristic: Bool,
         lineNumber: Int,
         snippet: String,
         file: String? = nil) {
        self.ruleID = ruleID
        self.category = category
        self.severity = severity
        self.title = title
        self.heuristic = heuristic
        self.lineNumber = lineNumber
        self.snippet = snippet
        self.file = file
    }

    var isInMainFile: Bool { file == nil }

    /// "line 12" or "scripts/run.sh:12"
    var locationText: String {
        if let file { return "\(file):\(lineNumber)" }
        return "line \(lineNumber)"
    }

    static func == (lhs: SecurityFinding, rhs: SecurityFinding) -> Bool {
        lhs.id == rhs.id
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct SecurityScanResult {
    let findings: [SecurityFinding]
    /// 0 (clean) – 100 (severe). Mirrors SkillSpector's risk score.
    let riskScore: Int
    /// Findings the user chose to ignore for this skill. Excluded from
    /// `findings`, the score, and every summary — kept so the UI can offer
    /// to un-ignore them.
    var suppressedFindings: [SecurityFinding] = []

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
        if let file = finding.file {
            return "\(finding.title) in \(file) line \(finding.lineNumber)"
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

    // MARK: Derived results

    /// Same scan with the given rule IDs moved into `suppressedFindings`.
    /// The score is recomputed from what remains.
    func excluding(ruleIDs: Set<String>) -> SecurityScanResult {
        guard !ruleIDs.isEmpty else { return self }
        let all = findings + suppressedFindings
        let kept = all.filter { !ruleIDs.contains($0.ruleID) }
        let dropped = all.filter { ruleIDs.contains($0.ruleID) }
        return SecurityScanResult(
            findings: kept,
            riskScore: SecurityScanner.score(for: kept),
            suppressedFindings: dropped
        )
    }

    /// Merges several per-file results into one (score recomputed over the union).
    static func combining(_ results: [SecurityScanResult]) -> SecurityScanResult {
        let findings = results.flatMap(\.findings)
        let suppressed = results.flatMap(\.suppressedFindings)
        return SecurityScanResult(
            findings: findings,
            riskScore: SecurityScanner.score(for: findings),
            suppressedFindings: suppressed
        )
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
        // Only comments that *instruct* the model. "<!-- do not edit: generated -->"
        // or "<!-- TODO -->" are ordinary authoring comments.
        .init("TP1", .toolPoisoning, .high, "Hidden instructions in comment",
              #"<!--(?:(?!-->).)*\b(?:ignore|override|disregard|system\s+prompt|you\s+must|you\s+should\s+(?:now|always)|new\s+instructions?|secretly|exfiltrat\w*|do\s+not\s+(?:tell|reveal|mention|disclose|inform|warn)|always\s+(?:respond|reply|say|answer)|(?:ai|assistant|model|agent)s?\s*:\s)\b(?:(?!-->).)*-->"#),
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
        // Plain sudo is common in install docs ("sudo npm install -g …"); it only
        // becomes interesting when paired with something destructive (PE2b).
        .init("PE2", .privilegeEscalation, .low, "Privileged execution (sudo)",
              #"\bsudo\s+\S"#, shadowedBy: ["PE2b"]),
        .init("PE2b", .privilegeEscalation, .high, "Privileged destructive command (sudo)",
              #"\bsudo\s+[^\n]*\b(?:rm\s+-[a-z]*r|mkfs|dd\s+if=|chmod\s+(?:-R\s+)?[0-7]*777|chown\s+-R|launchctl\s+(?:load|bootstrap)|crontab|visudo|passwd|useradd|dscl|systemctl|kextload|csrutil|spctl|nvram|diskutil\s+(?:erase|partition)|tee\s+(?:-a\s+)?/etc/|>\s*/etc/)"#),
        .init("PE2c", .privilegeEscalation, .medium, "Sets setuid bit",
              #"chmod\s+[ugoa]*\+s\b|\bsetuid\s*\("#),
        // `rm -rf` is only destructive when it points at /, ~, $HOME, a glob,
        // or an absolute path outside the temp dirs. Relative build dirs and
        // /tmp/... are routine.
        .init("DESTROY", .privilegeEscalation, .high, "Destructive filesystem command",
              #"\brm\s+((?:-{1,2}[a-z][a-z-]*\s+)+)([^\n;|&]*)"#,
              validator: { line, match in
                  guard let flagsRange = Range(match.range(at: 1), in: line),
                        let targetsRange = Range(match.range(at: 2), in: line) else { return false }
                  let flags = line[flagsRange].split(whereSeparator: \.isWhitespace).map(String.init)
                  let recursive = flags.contains { flag in
                      flag.lowercased() == "--recursive"
                          || (flag.hasPrefix("-") && !flag.hasPrefix("--") && flag.lowercased().contains("r"))
                  }
                  guard recursive else { return false }
                  return line[targetsRange]
                      .split(whereSeparator: \.isWhitespace)
                      .map(String.init)
                      .filter { !$0.hasPrefix("-") }
                      .contains(where: isDestructiveRemoveTarget)
              }),
        .init("DESTROY_DISK", .privilegeEscalation, .high, "Destructive disk command",
              #"\bmkfs\.|\bdd\s+if=.*of=/dev/"#),

        // --- Credential Access ---
        .init("PE3", .credentialAccess, .high, "Reads SSH keys / credentials",
              #"(\.ssh/(id_rsa|id_ed25519|authorized_keys)|\.aws/credentials|\.netrc|id_rsa\b)"#),
        .init("E2", .credentialAccess, .high, "Harvests environment secrets",
              #"(os\.environ|process\.env|getenv)\b[^\n]{0,40}(KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL)"#),
        .init("CRED", .credentialAccess, .medium, "Hardcoded secret",
              #"(api[_-]?key|secret|password|token)\s*[:=]\s*['"][A-Za-z0-9_\-]{16,}['"]"#),
        .init("KEY_OPENAI", .credentialAccess, .critical, "Exposed OpenAI API Key",
              #"sk-proj-[A-Za-z0-9_\-]{20,}|sk-[A-Za-z0-9]{48}"#),
        .init("KEY_ANTHROPIC", .credentialAccess, .critical, "Exposed Anthropic API Key",
              #"sk-ant-api03-[A-Za-z0-9_\-]{20,}|sk-ant-[A-Za-z0-9_\-]{20,}"#),
        .init("KEY_GITHUB", .credentialAccess, .critical, "Exposed GitHub Personal Access Token",
              #"ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9]{22}_[A-Za-z0-9]{59}"#),
        .init("KEY_AWS", .credentialAccess, .critical, "Exposed AWS Access Key ID",
              #"AKIA[0-9A-Z]{16}"#),
        .init("KEY_SSH_PRIV", .credentialAccess, .critical, "Hardcoded Private Key Block",
              #"-----BEGIN (RSA|OPENSSH|EC|DSA|PRIVATE) KEY-----"#),


        // --- Data Exfiltration ---
        .init("E1", .dataExfiltration, .medium, "POST to external endpoint",
              #"(requests\.post|fetch|axios\.post|http\.client|urllib\.request)\b[^\n]*https?://"#, heuristic: true),
        // netcat must be a whole word *and* sit where a command would: line
        // start, after a pipe/`;`/`&&`, or inside `$(…)`/backticks. "sync 2024"
        // is not netcat.
        .init("E1b", .dataExfiltration, .high, "Pipes data to remote netcat / curl upload",
              #"(?:^\s*(?:\$\s+)?|[|;&`(]\s*)(?:sudo\s+)?(?:nc|ncat|netcat)\b\s+[^\n]*\b\d{2,5}\b|\bcurl\b[^\n]*(?:--data\S*|--upload-file|(?<=\s)-[dTF])\b[^\n]*https?://"#),

        // --- Persistence ---
        .init("RA2", .persistence, .high, "Installs persistence (cron/launchd)",
              #"\bcrontab\s+-(?!l\b)|\|\s*crontab\b|/etc/cron\w*|\b(?:cp|mv|ln|tee|install|cat)\s[^\n]*Launch(?:Agents|Daemons)|>\s*[^\n]*Launch(?:Agents|Daemons)|\blaunchctl\s+(?:load|bootstrap|enable|submit)\b"#,
              heuristic: true),
        // Only *writes* to shell startup files count. "add this to your ~/.zshrc"
        // is documentation, `echo … >> ~/.zshrc` is persistence.
        .init("RA2b", .persistence, .high, "Writes to shell startup file",
              #"(?:>>?\s*|\btee\s+(?:-a\s+)?|\bsed\s+-i\S*\s+[^\n]*?)["']?[^\s"']*(?:\.(?:bashrc|zshrc|profile|bash_profile|zprofile|zshenv|zlogin)|/etc/rc\.local|/etc/profile)\b"#,
              heuristic: true),
        .init("RA1", .codeExecution, .critical, "Self-modifying code",
              #"open\s*\(\s*__file__|with\s+open\([^)]*__file__"#, heuristic: true),
    ]

    /// Targets that make a recursive `rm` dangerous: the root, the home
    /// directory (or anything under it), a bare glob, or an absolute path that
    /// isn't a scratch/temp location. Relative paths are treated as
    /// project-local build output and left alone.
    static func isDestructiveRemoveTarget(_ raw: String) -> Bool {
        let target = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
        guard !target.isEmpty, target != "--" else { return false }

        let dangerousExact: Set<String> = [
            "/", "/*", "~", "~/", "~/*", "$HOME", "${HOME}", "$HOME/", "${HOME}/", "$HOME/*", "${HOME}/*", "*",
        ]
        if dangerousExact.contains(target) { return true }

        if target.hasPrefix("~/") || target.hasPrefix("$HOME/") || target.hasPrefix("${HOME}/") {
            return true
        }
        if target.hasPrefix("$TMPDIR") || target.hasPrefix("${TMPDIR}") { return false }

        guard target.hasPrefix("/") else { return false } // relative: build/, ./dist, node_modules …

        let tempPrefixes = [
            "/tmp/", "/private/tmp/", "/var/tmp/", "/private/var/tmp/",
            "/var/folders/", "/private/var/folders/", "/dev/shm/",
        ]
        return !tempPrefixes.contains { target.hasPrefix($0) }
    }

    // MARK: Scan

    /// Memoizes results by exact text. `scan` is a pure function of its input,
    /// and the UI calls it from list filters, sort comparators, sidebar badges,
    /// and every row body — so without this each redraw re-ran every rule over
    /// every line of every skill. Also keeps `SecurityFinding.id` stable across
    /// redraws, which `ForEach` relies on. NSCache is thread-safe and evicts
    /// under memory pressure.
    private final class CachedScan {
        let result: SecurityScanResult
        init(_ result: SecurityScanResult) { self.result = result }
    }

    private static let scanCache: NSCache<NSString, CachedScan> = {
        let cache = NSCache<NSString, CachedScan>()
        cache.countLimit = 512
        return cache
    }()

    /// Scan arbitrary text (a skill's markdown body, an embedded script, etc.).
    ///
    /// - Parameter file: skill-relative path recorded on each finding when the
    ///   text is a bundled file rather than the main skill file. Line numbers
    ///   always restart at 1 for each call.
    static func scan(text: String, file: String? = nil) -> SecurityScanResult {
        guard !text.isEmpty else {
            return SecurityScanResult(findings: [], riskScore: 0)
        }

        let cacheKey = ((file ?? "") + "\u{0}" + text) as NSString
        if let cached = scanCache.object(forKey: cacheKey) {
            return cached.result
        }

        var findings: [SecurityFinding] = []
        let lines = text.components(separatedBy: .newlines)

        for (index, line) in lines.enumerated() {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            var matched: [SecurityRule] = []
            for rule in rules {
                guard let match = rule.pattern.firstMatch(in: line, range: range) else { continue }
                if let validator = rule.validator, !validator(line, match) { continue }
                matched.append(rule)
            }
            let matchedIDs = Set(matched.map(\.id))
            for rule in matched where rule.shadowedBy.isDisjoint(with: matchedIDs) {
                findings.append(
                    SecurityFinding(
                        ruleID: rule.id,
                        category: rule.category,
                        severity: rule.severity,
                        title: rule.title,
                        heuristic: rule.heuristic,
                        lineNumber: index + 1,
                        snippet: String(line.trimmingCharacters(in: .whitespaces).prefix(200)),
                        file: file
                    )
                )
            }
        }

        let result = SecurityScanResult(findings: findings, riskScore: score(for: findings))
        scanCache.setObject(CachedScan(result), forKey: cacheKey)
        return result
    }

    /// Saturating weighted score, capped at 100. A single critical never
    /// fully saturates the bar, so multiple findings still escalate.
    static func score(for findings: [SecurityFinding]) -> Int {
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
                out += "- **[\(finding.severity.label), +\(finding.severity.weight)]** \(finding.title)\(tag) — \(finding.category.rawValue), \(finding.locationText)\n"
            }
            if !result.suppressedFindings.isEmpty {
                let ids = Set(result.suppressedFindings.map(\.ruleID)).sorted().joined(separator: ", ")
                out += "- _Ignored for this skill: \(ids)_\n"
            }
        }

        out += "\n---\n_Static heuristic scan. Flags risky patterns, not a guarantee — review skills from untrusted sources yourself._\n"
        return out
    }
}
