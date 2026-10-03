import XCTest
#if canImport(SkillKitLib)
@testable import SkillKitLib
#else
@testable import SkillKit
#endif

final class AgentSkillSpecTests: XCTestCase {

    func testValidNames() {
        XCTAssertTrue(AgentSkillSpec.isValidName("pdf-tools"))
        XCTAssertTrue(AgentSkillSpec.isValidName("a1"))
        XCTAssertTrue(AgentSkillSpec.isValidName(String(repeating: "a", count: 64)))
    }

    func testNameProblems() {
        XCTAssertEqual(AgentSkillSpec.nameProblems("PDF Tools"), [.invalidCharacters])
        XCTAssertEqual(AgentSkillSpec.nameProblems("-pdf"), [.badHyphens])
        XCTAssertEqual(AgentSkillSpec.nameProblems("pdf--tools"), [.badHyphens])
        XCTAssertEqual(AgentSkillSpec.nameProblems(String(repeating: "a", count: 65)), [.tooLong(65)])
        XCTAssertEqual(AgentSkillSpec.nameProblems(""), [], "empty names are reported by the missing-name check")
    }

    func testNormalizedName() {
        XCTAssertEqual(AgentSkillSpec.normalizedName("PDF Tools"), "pdf-tools")
        XCTAssertEqual(AgentSkillSpec.normalizedName("  Café__Helper!! "), "cafe-helper")
        XCTAssertEqual(AgentSkillSpec.normalizedName("--a--b--"), "a-b")
        XCTAssertEqual(AgentSkillSpec.normalizedName("!!!"), "")
        let long = AgentSkillSpec.normalizedName(String(repeating: "ab ", count: 40))
        XCTAssertLessThanOrEqual(long.count, 64)
        XCTAssertTrue(AgentSkillSpec.isValidName(long))
    }

    func testSuggestedNamePrefersValidFolder() {
        XCTAssertEqual(AgentSkillSpec.suggestedName(for: "PDF Tools", folderName: "pdf"), "pdf")
        XCTAssertEqual(AgentSkillSpec.suggestedName(for: "PDF Tools", folderName: "My Folder"), "pdf-tools")
        XCTAssertEqual(AgentSkillSpec.suggestedName(for: "PDF Tools", folderName: nil), "pdf-tools")
    }

    func testFolderNameOnlyForDirectorySkills() {
        XCTAssertEqual(AgentSkillSpec.folderName(forSkillAt: "/x/skills/pdf/SKILL.md", isDirectory: true), "pdf")
        XCTAssertNil(AgentSkillSpec.folderName(forSkillAt: "/x/rules/pdf.md", isDirectory: false))
    }

    func testValidationFlagsSpecBreaks() {
        let longDescription = String(repeating: "x", count: 1100)
        let skill = makeSkill(name: "PDF Tools", description: longDescription)
        let ids = Set(skill.validationIssues.map(\.id))
        XCTAssertTrue(ids.contains("spec-name-format"))
        XCTAssertTrue(ids.contains("spec-description-length"))
        XCTAssertFalse(ids.contains("spec-name-folder-mismatch"), "a bad name is reported once, as a format problem")
    }

    func testValidationFlagsFolderMismatch() {
        let skill = makeSkill(name: "pdf-tools", folder: "pdf")
        let issue = skill.validationIssues.first { $0.id == "spec-name-folder-mismatch" }
        XCTAssertEqual(issue?.severity, .info)
    }

    func testValidationSkipsRules() {
        let rule = makeSkill(name: "My Rule", kind: .rule)
        XCTAssertFalse(rule.validationIssues.contains { $0.id.hasPrefix("spec-") })
    }

    func testLinterFixRenamesToFolder() {
        let skill = makeSkill(name: "PDF Tools", folder: "pdf")
        let content = "---\nname: PDF Tools\ndescription: Work with PDFs.\n---\n\nBody\n"
        let fix = SkillLinter.fixes(for: content, skill: skill).first { $0.id == "fix-skill-name" }
        XCTAssertEqual(fix?.apply(content, skill), "---\nname: pdf\ndescription: Work with PDFs.\n---\n\nBody\n")
    }

    func testLinterFixKeepsCRLFAndSkipsBlockScalars() {
        let skill = makeSkill(name: "PDF Tools", folder: "pdf")
        let crlf = "---\r\nname: \"PDF Tools\"\r\ndescription: d\r\n---\r\nBody\r\n"
        let fix = SkillLinter.fixes(for: crlf, skill: skill).first { $0.id == "fix-skill-name" }
        XCTAssertEqual(fix?.apply(crlf, skill), "---\r\nname: pdf\r\ndescription: d\r\n---\r\nBody\r\n")

        let block = "---\nname: >\n  PDF Tools\n---\nBody\n"
        XCTAssertEqual(fix?.apply(block, skill), block)
    }

    func testNoLinterFixForCompliantName() {
        let skill = makeSkill(name: "pdf", folder: "pdf")
        let content = "---\nname: pdf\ndescription: d\n---\nBody\n"
        XCTAssertFalse(SkillLinter.fixes(for: content, skill: skill).contains { $0.id == "fix-skill-name" })
    }

    private func makeSkill(name: String, description: String = "Work with PDFs.", folder: String = "pdf", kind: ItemKind = .skill) -> Skill {
        let path = "/tmp/skillkit-tests/\(folder)/SKILL.md"
        return Skill(
            filePath: path,
            toolSource: .claude,
            isDirectory: kind == .skill,
            name: name,
            skillDescription: description,
            content: "Body",
            frontmatter: ["name": name, "description": description],
            resolvedPath: path,
            kind: kind
        )
    }
}

final class SkillSimilarityTests: XCTestCase {
    private let base = """
    Always run the test suite before committing. Prefer small focused commits with
    descriptive messages. Never force push to the main branch without asking first.
    Keep pull requests under four hundred lines when possible.
    """

    func testFindsNearDuplicates() {
        let edited = base.replacingOccurrences(of: "four hundred", with: "five hundred")
        let unrelated = """
        Format every Swift file with the project style guide. Use four spaces for
        indentation and keep lines under one hundred and twenty characters wide.
        """
        let matches = SkillSimilarity.matches(in: [
            .init(id: "a", text: base),
            .init(id: "b", text: edited),
            .init(id: "c", text: unrelated),
        ])
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(Set([matches[0].leftID, matches[0].rightID]), ["a", "b"])
        XCTAssertGreaterThanOrEqual(matches[0].similarity, SkillSimilarity.defaultThreshold)
    }

    func testIgnoresCaseAndPunctuation() {
        XCTAssertEqual(SkillSimilarity.similarity(base, base.uppercased().replacingOccurrences(of: ".", with: "!")), 1)
    }

    func testSkipsTinyDocuments() {
        let matches = SkillSimilarity.matches(in: [
            .init(id: "a", text: "Be concise."),
            .init(id: "b", text: "Be concise."),
        ])
        XCTAssertTrue(matches.isEmpty)
    }

    func testSortedMostSimilarFirst() {
        let lightly = base + " Also add a changelog entry."
        let heavily = base.replacingOccurrences(of: "four hundred", with: "five hundred") + " Also add a changelog entry."
        let matches = SkillSimilarity.matches(in: [
            .init(id: "a", text: base),
            .init(id: "b", text: base),
            .init(id: "c", text: lightly),
            .init(id: "d", text: heavily),
        ], threshold: 0.5)
        XCTAssertEqual(matches.first?.similarity, 1)
        XCTAssertEqual(matches.map(\.similarity), matches.map(\.similarity).sorted(by: >))
    }
}

final class ContextBudgetTests: XCTestCase {

    func testSkillsCountMetadataRulesCountBody() {
        let body = String(repeating: "x", count: 4000)
        let entries = ContextBudget.entries(for: [
            .init(tools: [.claude], kind: .skill, name: "pdfs", description: String(repeating: "d", count: 36), content: body),
            .init(tools: [.claude, .cursor], kind: .rule, name: "style", description: "", content: body),
        ])

        let claude = entries.first { $0.tool == .claude }
        XCTAssertEqual(claude?.skillCount, 1)
        XCTAssertEqual(claude?.ruleCount, 1)
        XCTAssertEqual(claude?.skillMetadataTokens, 1 + 9, "the skill body is not counted")
        XCTAssertEqual(claude?.ruleTokens, 1000)

        let cursor = entries.first { $0.tool == .cursor }
        XCTAssertEqual(cursor?.totalTokens, 1000)
        XCTAssertEqual(entries.first?.tool, .claude, "largest total first")
    }

    func testDuplicateToolsCountOnce() {
        let entries = ContextBudget.entries(for: [
            .init(tools: [.claude, .claude], kind: .rule, name: "r", description: "", content: "abcd"),
        ])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].ruleCount, 1)
    }

    func testFormatting() {
        XCTAssertEqual(ContextBudget.formatted(950), "~950")
        XCTAssertEqual(ContextBudget.formatted(12_340), "~12.3k")
    }
}

final class SkillSearchQueryTests: XCTestCase {

    func testParsesTermsPhrasesAndFilters() {
        let query = SkillSearchQuery(#"pdf "merge files" -draft tool:cursor -is:rule note:x"#)
        XCTAssertEqual(query.terms, [
            .init(text: "pdf", negated: false),
            .init(text: "merge files", negated: false),
            .init(text: "draft", negated: true),
            .init(text: "note:x", negated: false),
        ])
        XCTAssertEqual(query.conditions, [
            .init(filter: .tool("cursor"), negated: false),
            .init(filter: .flag(.rule), negated: true),
        ])
    }

    func testUnknownFlagAndQuotedFilterAreText() {
        let query = SkillSearchQuery(#"is:bogus "tool:cursor""#)
        XCTAssertTrue(query.conditions.isEmpty)
        XCTAssertEqual(query.terms.map(\.text), ["is:bogus", "tool:cursor"])
    }

    func testBlankAndStrayTokens() {
        XCTAssertTrue(SkillSearchQuery("   ").isEmpty)
        XCTAssertTrue(SkillSearchQuery(#"- "" -"#).isEmpty)
        XCTAssertEqual(SkillSearchQuery(#""unclosed phrase"#).terms.map(\.text), ["unclosed phrase"])
    }

    func testWordsMatchInAnyOrder() {
        let skill = makeSkill(name: "Tools", content: "Merge PDF files quickly.")
        XCTAssertTrue(skill.matches(SkillSearchQuery("pdf tools"), in: .all))
        XCTAssertTrue(skill.matches(SkillSearchQuery("files merge"), in: .all))
        XCTAssertFalse(skill.matches(SkillSearchQuery(#""files merge""#), in: .all))
        XCTAssertFalse(skill.matches(SkillSearchQuery("pdf tools"), in: .title), "scope still applies to every word")
    }

    func testExclusionAndFlags() {
        let rule = makeSkill(name: "Style", content: "Use tabs.", kind: .rule, tool: .cursor, favorite: true)
        XCTAssertTrue(rule.matches(SkillSearchQuery("is:rule tool:cursor"), in: .all))
        XCTAssertTrue(rule.matches(SkillSearchQuery("tool:Cursor is:fav"), in: .all))
        XCTAssertFalse(rule.matches(SkillSearchQuery("is:skill"), in: .all))
        XCTAssertFalse(rule.matches(SkillSearchQuery("-is:rule"), in: .all))
        XCTAssertFalse(rule.matches(SkillSearchQuery("style -tabs"), in: .all))
        XCTAssertFalse(rule.matches(SkillSearchQuery("tool:codex"), in: .all))
    }

    private func makeSkill(name: String, content: String, kind: ItemKind = .skill, tool: ToolSource = .claude, favorite: Bool = false) -> Skill {
        let path = "/tmp/skillkit-search/\(name).md"
        return Skill(
            filePath: path,
            toolSource: tool,
            name: name,
            content: content,
            isFavorite: favorite,
            resolvedPath: path,
            kind: kind
        )
    }
}
