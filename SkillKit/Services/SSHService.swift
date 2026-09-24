import Foundation

enum SSHError: LocalizedError {
    case connectionFailed(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg): "SSH connection failed: \(msg)"
        case .commandFailed(let msg): "SSH command failed: \(msg)"
        }
    }
}

enum SSHService {
    private static let sshPath = "/usr/bin/ssh"

    private static func baseArgs(for server: RemoteServer) -> [String] {
        let home = AppPaths.userHomeDirectory
        var args = [
            "-p", "\(server.port)",
            "-o", "ConnectTimeout=10",
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=accept-new",
        ]

        if let keyPath = server.sshKeyPath, !keyPath.isEmpty {
            // User-specified key path (expand ~ if present)
            let resolved = keyPath.hasPrefix("~/")
                ? home + keyPath.dropFirst(1)
                : keyPath
            args += ["-i", resolved]
        } else {
            // Auto-discover common default key names
            let defaultKeys = ["id_ed25519", "id_rsa", "id_ecdsa"]
            for name in defaultKeys {
                let path = "\(home)/.ssh/\(name)"
                if FileManager.default.fileExists(atPath: path) {
                    args += ["-i", path]
                    break
                }
            }
        }

        // `--` ends option parsing, so a destination starting with `-` can't be read as
        // an ssh option such as `-oProxyCommand=…`.
        args += ["--", server.sshDestination]
        return args
    }

    /// Escapes a string for safe use inside single quotes in a shell command.
    private static func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Public API

    static func testConnection(_ server: RemoteServer) async throws {
        let (_, stderr, code) = try await run(
            args: baseArgs(for: server) + ["echo", "ok"]
        )
        if code != 0 {
            throw SSHError.connectionFailed(stderr)
        }
    }

    /// Escapes a path for the remote shell, handling tilde expansion.
    /// Uses double quotes so a leading `~` can become `$HOME` while spaces are preserved;
    /// everything the user typed is escaped, so `$(…)`, backticks and `\` stay literal.
    static func shellQuotePath(_ path: String) -> String {
        var home = ""
        var rest = Substring(path)
        if path.hasPrefix("~/") {
            home = "$HOME/"
            rest = path.dropFirst(2)
        } else if path == "~" {
            home = "$HOME"
            rest = ""
        }
        var escaped = ""
        for character in rest {
            if "\\\"$`".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return "\"\(home)\(escaped)\""
    }

    /// The result of listing a server's skills. `listedPaths` holds every `SKILL.md` that
    /// `find` reported, including any that could not be read, so a sync only drops rows for
    /// skills that are really gone rather than ones that were briefly unreadable.
    struct RemoteListing {
        let skills: [(path: String, content: String)]
        let listedPaths: Set<String>
    }

    static func findSkills(_ server: RemoteServer) async throws -> RemoteListing {
        let basePath = shellQuotePath(server.skillsBasePath)

        // Find all SKILL.md files under the base path
        let findCmd = "find \(basePath) -name 'SKILL.md' -type f 2>/dev/null"
        let (stdout, stderr, code) = try await run(
            args: baseArgs(for: server) + [findCmd]
        )

        // 255 is ssh's own failure. `find` exits 1 when any subdirectory is unreadable,
        // which still leaves the rest of the listing usable.
        if code == 255 {
            throw SSHError.connectionFailed(stderr.isEmpty ? "Connection failed (exit code \(code))" : stderr)
        }

        let paths = stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        if code != 0 && paths.isEmpty {
            // Most likely a missing or unreadable base path. Report it instead of returning
            // an empty listing, which would remove every synced skill from the library.
            throw SSHError.commandFailed("Could not list \(server.skillsBasePath) on the server (exit code \(code)).")
        }
        if paths.isEmpty { return RemoteListing(skills: [], listedPaths: []) }

        // Read all files in a single SSH call.
        let combined = readCommand(for: paths)
        let (content, errorOutput, exitCode) = try await run(
            args: baseArgs(for: server) + [combined]
        )
        if exitCode != 0 && content.isEmpty {
            throw SSHError.commandFailed(
                errorOutput.isEmpty ? "Could not read skills from the server." : errorOutput
            )
        }

        let skills = parseDelimitedOutput(content).map { (path: repairLegacyRemotePath($0.path), content: $0.content) }
        return RemoteListing(skills: skills, listedPaths: Set(paths))
    }

    /// Builds the single remote command that prints every readable file behind its own
    /// delimiter line. Commands are joined with `;` so one unreadable file doesn't stop the
    /// rest, and each delimiter is preceded by a newline so a file without a trailing
    /// newline can't glue itself onto the next delimiter. `parseDelimitedOutput` reverses
    /// this exactly: that extra newline is what terminates the previous file's last line.
    /// The delimiter argument is escaped too: a path containing a quote would otherwise
    /// break out of it and turn the whole chain into a syntax error.
    static func readCommand(for paths: [String]) -> String {
        paths.map { path in
            let file = shellEscape(path)
            let delimiter = shellEscape(delimiterPrefix + path + delimiterSuffix)
            return "if [ -r \(file) ]; then printf '\\n%s\\n' \(delimiter); cat \(file); fi"
        }
        .joined(separator: "; ")
    }

    // MARK: - Path helpers

    /// Delimiter line prefix emitted by `findSkills` before each remote file's content.
    static let delimiterPrefix = "---SKILLKIT_DELIM:"
    static let delimiterSuffix = "---"

    /// Earlier builds sliced the delimiter line at a fixed offset that was three characters
    /// short, so every remote path was persisted as `IM:/home/...`. Strips that artifact.
    /// Safe to call on already-correct paths.
    static func repairLegacyRemotePath(_ path: String) -> String {
        if path.hasPrefix("IM:") {
            return String(path.dropFirst(3))
        }
        return path
    }

    /// Returns true when an SSH error message indicates the server rejected our key/agent
    /// authentication — the only kind SkillKit supports because ssh runs with `BatchMode=yes`
    /// and can never prompt for a password or passphrase.
    static func isAuthenticationFailure(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("permission denied") || lower.contains("publickey")
    }

    /// Friendly guidance shown instead of raw stderr for authentication failures.
    static let authenticationGuidance =
        "SkillKit can't prompt for passwords or key passphrases. Load your key into ssh-agent (`ssh-add ~/.ssh/id_ed25519`) or choose an unencrypted key file."

    static func readFile(_ server: RemoteServer, path: String) async throws -> String {
        let (stdout, stderr, code) = try await run(
            args: baseArgs(for: server) + ["cat \(shellEscape(path))"]
        )
        if code != 0 {
            throw SSHError.commandFailed(stderr)
        }
        return stdout
    }

    static func writeFile(_ server: RemoteServer, path: String, content: String) async throws {
        // Ensure parent directory exists, then write via stdin
        let escaped = shellEscape(path)
        let mkdirCmd = "mkdir -p \"$(dirname \(escaped))\" && cat > \(escaped)"
        let (_, stderr, code) = try await run(
            args: baseArgs(for: server) + [mkdirCmd],
            stdin: content
        )
        if code != 0 {
            throw SSHError.commandFailed(stderr)
        }
    }

    // MARK: - Private

    private static func run(args: [String], stdin stdinContent: String? = nil) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: sshPath)
                process.arguments = args

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                let stdinPipe = stdinContent.map { _ in Pipe() }
                process.standardInput = stdinPipe ?? FileHandle.nullDevice

                do {
                    try process.run()

                    // Feed stdin only once the child is running, and from another thread:
                    // content larger than the pipe buffer would otherwise block forever
                    // with nobody reading the other end.
                    if let stdinPipe, let stdinContent {
                        let data = Data(stdinContent.utf8)
                        // If ssh exits early (auth failure) the write hits a closed pipe;
                        // report EPIPE instead of letting SIGPIPE terminate the app.
                        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                        DispatchQueue.global(qos: .userInitiated).async {
                            try? stdinPipe.fileHandleForWriting.write(contentsOf: data)
                            try? stdinPipe.fileHandleForWriting.close()
                        }
                    }

                    // Drain both pipes concurrently with the process running, not
                    // after `waitUntilExit()`. `findSkills` cats every remote
                    // skill file into one command's stdout, so once combined
                    // output exceeds the OS pipe buffer (64KB) the child blocks
                    // writing to a full pipe while we'd otherwise block waiting
                    // for it to exit — a deadlock. Reading concurrently keeps
                    // the pipe draining the whole time.
                    let readGroup = DispatchGroup()
                    var stdoutData = Data()
                    var stderrData = Data()

                    readGroup.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                        readGroup.leave()
                    }
                    readGroup.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                        readGroup.leave()
                    }

                    process.waitUntilExit()
                    readGroup.wait()

                    let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                    let stderr = String(data: stderrData, encoding: .utf8) ?? ""

                    continuation.resume(returning: (stdout, stderr, process.terminationStatus))
                } catch {
                    continuation.resume(throwing: SSHError.connectionFailed(error.localizedDescription))
                }
            }
        }
    }

    /// Splits the combined `echo '---SKILLKIT_DELIM:<path>---' && cat <path>` output produced by
    /// `findSkills` into (path, content) pairs. Internal for unit testing.
    static func parseDelimitedOutput(_ output: String) -> [(path: String, content: String)] {
        var results: [(path: String, content: String)] = []
        let lines = output.components(separatedBy: "\n")
        var currentPath: String?
        var currentLines: [String] = []

        for line in lines {
            if line.hasPrefix(delimiterPrefix) && line.hasSuffix(delimiterSuffix)
                && line.count >= delimiterPrefix.count + delimiterSuffix.count {
                // Save previous block
                if let path = currentPath {
                    results.append((path: path, content: currentLines.joined(separator: "\n")))
                }
                // Extract path from delimiter: strip the exact prefix and suffix rather than
                // slicing at a hardcoded offset (a stale offset once produced "IM:/..." paths).
                currentPath = String(line.dropFirst(delimiterPrefix.count).dropLast(delimiterSuffix.count))
                currentLines = []
            } else {
                currentLines.append(line)
            }
        }

        // Save last block
        if let path = currentPath {
            results.append((path: path, content: currentLines.joined(separator: "\n")))
        }

        return results
    }
}
