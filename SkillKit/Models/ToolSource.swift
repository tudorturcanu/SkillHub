import SwiftUI

enum ToolSource: String, Codable, CaseIterable, Identifiable {
    case agents
    case augment
    case claude
    case cursor
    case windsurf
    case codex
    case copilot
    case aider
    case amp
    case hermes
    case openclaw
    case opencode
    case pi
    case antigravity
    case claudeDesktop
    case custom

    var id: String { rawValue }

    /// Whether this tool should appear in the sidebar tools list.
    var listable: Bool {
        switch self {
        case .custom, .claudeDesktop, .aider:
            return false
        default:
            return true
        }
    }

    var displayName: String {
        switch self {
        case .augment: "Auggie"
        case .claude: "Claude Code"
        case .cursor: "Cursor"
        case .windsurf: "Windsurf"
        case .codex: "Codex"
        case .copilot: "Copilot"
        case .aider: "Aider"
        case .amp: "Amp"
        case .hermes: "Hermes"
        case .openclaw: "OpenClaw"
        case .opencode: "OpenCode"
        case .pi: "Pi"
        case .agents: "Global"
        case .antigravity: "Antigravity"
        case .claudeDesktop: "Claude Desktop"
        case .custom: "Custom"
        }
    }

    /// SF Symbol fallback icon name
    var iconName: String {
        switch self {
        case .augment: "wand.and.sparkles"
        case .claude: "brain.head.profile"
        case .cursor: "cursorarrow.rays"
        case .windsurf: "wind"
        case .codex: "book.closed"
        case .copilot: "airplane"
        case .aider: "wrench.and.screwdriver"
        case .amp: "bolt.fill"
        case .hermes: "bolt.horizontal.circle"
        case .openclaw: "server.rack"
        case .opencode: "terminal"
        case .pi: "sparkles"
        case .agents: "globe"
        case .antigravity: "arrow.up.circle"
        case .claudeDesktop: "desktopcomputer"
        case .custom: "folder"
        }
    }

    /// Asset catalog image name, nil if no custom logo
    var logoAssetName: String? {
        switch self {
        case .augment: "tool-augment"
        case .claude: "tool-claude"
        case .cursor: "tool-cursor"
        case .codex: "tool-codex"
        case .windsurf: "tool-windsurf"
        case .copilot: "tool-copilot"
        case .amp: "tool-amp"
        case .antigravity: "tool-antigravity"
        case .claudeDesktop: "tool-claude"
        case .opencode: "tool-opencode"
        default: nil
        }
    }

    var color: Color {
        switch self {
        case .augment: .cyan
        case .claude: .orange
        case .cursor: .blue
        case .windsurf: .teal
        case .codex: .green
        case .copilot: .purple
        case .aider: .yellow
        case .amp: .pink
        case .hermes: .brown
        case .openclaw: .indigo
        case .opencode: .red
        case .pi: .cyan
        case .agents: .mint
        case .antigravity: .red
        case .claudeDesktop: .orange
        case .custom: .gray
        }
    }

    var globalAgentPaths: [String] {
        let sotDir = SkillKitSettings.sotDir
        switch self {
        case .claude: return ["\(sotDir)/claude/agents"]
        case .cursor: return ["\(sotDir)/cursor/agents"]
        case .codex: return ["\(sotDir)/codex/agents"]
        default: return []
        }
    }

    var globalPaths: [String] {
        let sotDir = SkillKitSettings.sotDir
        switch self {
        case .augment: return ["\(sotDir)/augment/skills"]
        case .claude: return ["\(sotDir)/claude/skills"]
        case .cursor: return ["\(sotDir)/cursor/skills"]
        case .windsurf: return []
        case .codex: return ["\(sotDir)/codex/skills"]
        case .copilot: return ["\(sotDir)/copilot/skills"]
        case .aider: return []
        case .amp: return ["\(sotDir)/amp/skills"]
        case .hermes: return ["\(sotDir)/hermes/skills"]
        case .openclaw: return ["\(sotDir)/openclaw/skills"]
        case .opencode: return ["\(sotDir)/opencode/skills"]
        case .pi: return ["\(sotDir)/pi/agent/skills"]
        case .agents: return sotDir.hasSuffix(".agents") ? ["\(sotDir)/skills"] : ["\(sotDir)/agents/skills"]
        case .antigravity: return ["\(sotDir)/antigravity/skills"]
        case .claudeDesktop: return []
        case .custom: return []
        }
    }

    var globalRulePaths: [String] {
        let sotDir = SkillKitSettings.sotDir
        switch self {
        case .cursor: return ["\(sotDir)/cursor/rules"]
        case .windsurf: return ["\(sotDir)/windsurf/memories", "\(sotDir)/windsurf/rules"]
        default: return []
        }
    }

    /// Whether the tool is actually installed on this machine.
    /// In Sandbox, we return true for all listable/custom tools to ensure they can be used and managed.
    var isInstalled: Bool {
        if self == .agents { return true }

        let fileManager = FileManager.default
        if (globalPaths + globalAgentPaths + globalRulePaths)
            .map({ ($0 as NSString).expandingTildeInPath })
            .contains(where: fileManager.fileExists) {
            return true
        }

        switch self {
        case .claude, .codex:
            return cliBinaryURL != nil
        default:
            return false
        }
    }

    private static func appBundleExists(_ name: String) -> Bool {
        let fm = FileManager.default
        let home = AppPaths.userHomeDirectory
        let paths = [
            "/Applications/\(name).app",
            "\(home)/Applications/\(name).app",
        ]
        return paths.contains { fm.fileExists(atPath: $0) }
    }

    private static func cliBinaryExists(_ name: String) -> Bool {
        cliBinaryURL(name) != nil
    }

    /// Resolves an executable name to an absolute file URL. Consults the user's login-shell
    /// PATH when it has already been captured (see `AgentBinaryResolver`), then probes the
    /// standard install locations and active nvm node versions. Never blocks on a shell.
    /// Returns nil if not found.
    static func cliBinaryURL(_ name: String, extraPaths: [String] = []) -> URL? {
        AgentBinaryResolver.shared.resolveCached(name: name, agentId: nil, extraPaths: extraPaths)?.url
    }

    /// Extra, tool-specific locations to probe for the CLI binary.
    private var cliExtraProbePaths: [String] {
        let home = AppPaths.userHomeDirectory
        switch self {
        case .codex: return ["\(home)/.codex/bin/codex"]
        default: return []
        }
    }

    /// Name of the CLI executable for tools that can be driven directly via subprocess.
    var cliBinaryName: String? {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        default: nil
        }
    }

    /// The `AgentID` whose user-chosen binary override applies to this tool, if any.
    private var cliAgentID: AgentID? {
        switch self {
        case .claude: .claude
        case .codex: .codex
        default: nil
        }
    }

    /// Resolved binary URL for tools that can be driven directly via subprocess.
    /// Currently used by Claude and Codex transports. Non-blocking: uses the user's
    /// override, the cached login-shell PATH, then the fixed probe list. Call
    /// `resolveCLIBinaryURL()` to also query the login shell when it hasn't run yet.
    var cliBinaryURL: URL? {
        cliBinaryResolution?.url
    }

    /// Like `cliBinaryURL` but also reports where the binary came from.
    var cliBinaryResolution: AgentBinaryResolver.Resolution? {
        guard let name = cliBinaryName else { return nil }
        return AgentBinaryResolver.shared.resolveCached(name: name, agentId: cliAgentID, extraPaths: cliExtraProbePaths)
    }

    /// Full async resolution (override → login-shell PATH → probes). Spawns the user's
    /// login shell at most once per process.
    func resolveCLIBinary() async -> AgentBinaryResolver.Resolution? {
        guard let name = cliBinaryName else { return nil }
        return await AgentBinaryResolver.shared.resolve(name: name, agentId: cliAgentID, extraPaths: cliExtraProbePaths)
    }

    func resolveCLIBinaryURL() async -> URL? {
        await resolveCLIBinary()?.url
    }

    /// Prepares an environment dictionary whose PATH contains the same directories the
    /// binary was resolved from (login-shell PATH, override dir) plus the common terminal
    /// search paths (Homebrew, nvm, local node, etc.) so subprocesses can locate Node.
    static func envWithResolvedPATH(for agentId: AgentID? = nil) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        var pathComponents = AgentBinaryResolver.shared.launchPATHComponents(for: agentId)
        for existing in (env["PATH"] ?? "").components(separatedBy: ":") where !existing.isEmpty {
            if !pathComponents.contains(existing) {
                pathComponents.append(existing)
            }
        }
        env["PATH"] = pathComponents.joined(separator: ":")
        return env
    }

    /// Runs `<bin> --version` and parses semver. Returns nil if the binary is missing
    /// or the output doesn't match an expected pattern. Pass `binary` to check a specific
    /// executable (e.g. one just resolved via `resolveCLIBinaryURL()`).
    func cliVersion(binary: URL? = nil) async -> (major: Int, minor: Int, patch: Int)? {
        guard let url = binary ?? cliBinaryURL else { return nil }
        let env = Self.envWithResolvedPATH(for: cliAgentID)
        // Run the blocking probe on a dedicated queue rather than the cooperative pool,
        // so a wedged CLI can't hold one of Swift concurrency's worker threads for 10s.
        let raw: String? = await withCheckedContinuation { continuation in
            Self.processQueue.async {
                continuation.resume(
                    returning: Self.captureStdout(of: url, arguments: ["--version"], environment: env, timeout: 10)
                )
            }
        }
        guard let raw else { return nil }
        let pattern = #/(\d+)\.(\d+)\.(\d+)/#
        guard let match = raw.firstMatch(of: pattern),
              let major = Int(match.output.1),
              let minor = Int(match.output.2),
              let patch = Int(match.output.3) else {
            return nil
        }
        return (major, minor, patch)
    }

    /// Where the blocking `captureStdout` waits live when called from async code.
    private static let processQueue = DispatchQueue(
        label: "alice.turcanu.com.SkillKit.ToolSource.process",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// Async wrapper around `captureStdout` that waits on `processQueue` rather
    /// than occupying a Swift concurrency cooperative thread for the timeout.
    nonisolated static func captureStdoutAsync(
        of url: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) async -> String? {
        await withCheckedContinuation { continuation in
            processQueue.async {
                continuation.resume(
                    returning: captureStdout(
                        of: url,
                        arguments: arguments,
                        environment: environment,
                        timeout: timeout
                    )
                )
            }
        }
    }

    /// Runs `url arguments` and returns its stdout, or nil on launch failure, non-zero exit
    /// or timeout. Blocking — call off the main thread. Reads concurrently and bounds the
    /// wait so a wedged CLI can't hang the caller.
    nonisolated static func captureStdout(
        of url: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) -> String? {
        let proc = Process()
        proc.executableURL = url
        proc.arguments = arguments
        proc.environment = environment
        proc.standardInput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        proc.standardOutput = pipe

        // Wait on the termination handler rather than polling `isRunning`. Installed
        // before `run()` so a process that exits immediately still signals us.
        let exited = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in exited.signal() }

        do {
            try proc.run()
        } catch {
            return nil
        }
        let readDone = DispatchSemaphore(value: 0)
        var data = Data()
        DispatchQueue.global(qos: .userInitiated).async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            readDone.signal()
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            proc.terminate()
            // The reader may still be appending to `data`; reading it here would race.
            return nil
        }
        // `data` is only safe to read once the reader has handed it over.
        guard readDone.wait(timeout: .now() + 1) == .success else { return nil }
        guard proc.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
