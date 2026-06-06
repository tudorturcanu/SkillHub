# SkillKit 🛠️

SkillKit is the native macOS mission control for AI coding-agent skills, rules, and system prompts. 

Instead of letting your instructions lie scattered across Claude Code, Codex, Cursor, Windsurf, Amp, and other developer folders, SkillKit gathers them into a unified, lightning-fast native interface. Search, edit, group, and reuse your agent skills from a single source of truth.

---

## Key Features

- **Unified Developer Dashboard**: View aggregated statistics (total skills, active rules, agents, and connected servers) alongside a real-time recent activity stream.
- **Native SwiftUI Editor & Preview**: A fully syntax-highlighted Markdown editor with autosave indicators and a live side-by-side HTML preview that parses frontmatter metadata.
- **Interactive Agent Chat**: Refine or refactor your instructions by chatting directly with your active local agent (e.g. Claude Code, Codex) from within the app.
- **Visual Diff Review**: Inspect, accept, or reject edits suggested by the agent through a native side-by-side diff review panel.
- **Multi-Platform Probing**: Automatically detects and scans project-local config folders, global config directories, and even CLI/Desktop plugins.
- **SSH Remote VM Syncing**: Sync and manage skills on remote servers/VMs over SSH using secure connection profiles.
- **Release Readiness Check**: Audit your app metadata, Sandboxed folder access bookmarks, and privacy settings before deployment to App Store Connect.

---

## Scanned Agent Config Directories

SkillKit scans both **project-local directories** and **global configuration paths** for agent instruction files (skipping generic readme, changelog, and license files).

| Tool / Platform | Display Name | Project Path | Global Config Paths |
| :--- | :--- | :--- | :--- |
| **Claude Code** | Claude Code | `.claude/skills`, `.claude/agents` | `~/.agents/claude/skills`, `~/.agents/claude/agents` |
| **Cursor** | Cursor | `.cursor/skills`, `.cursor/rules`, `.cursor/agents` | `~/.agents/cursor/skills`, `~/.agents/cursor/rules` |
| **Codex** | Codex | `.codex/skills`, `.codex/agents` | `~/.agents/codex/skills`, `~/.agents/codex/agents` |
| **Windsurf** | Windsurf | `.windsurf/rules` | `~/.agents/windsurf/rules`, `~/.agents/windsurf/memories` |
| **Copilot** | Copilot | `.github/copilot-instructions.md`, `.github/agents` | `~/.agents/copilot/skills` |
| **Amp** | Amp | `.config/amp/skills` | `~/.agents/amp/skills` |
| **OpenCode** | OpenCode | `.opencode/skills` | `~/.agents/opencode/skills` |
| **Hermes** | Hermes | `.hermes/skills` | `~/.agents/hermes/skills` |
| **Augment** | Auggie | — | `~/.agents/augment/skills` |
| **Pi** | Pi | — | `~/.agents/pi/agent/skills` |
| **Antigravity** | Antigravity | — | `~/.agents/antigravity/skills` |

### User Source of Truth (`sotDir`)

By default, the global source of truth directory resides at:
* Local Library: `~/Library/Application Support/SkillKit/LocalLibrary/`
* Can be customized via App Settings to a custom path (e.g., `~/.agents`) to sync across your terminal profiles.

---

## System Requirements

- **macOS 15.0** or later
- **Xcode 16.0+** with Command Line Tools
- **XcodeGen** (`brew install xcodegen`)
- **Highlightr** and **cmark-gfm** package dependencies (automatically resolved by Swift Package Manager)

---

## Build & Setup Instructions

SkillKit uses `XcodeGen` to generate its Xcode project file dynamically.

### 1. Generate the Project
Navigate to the root directory and generate the `.xcodeproj` file:
```bash
xcodegen generate
```

### 2. Build via CLI
To build the app in Debug configuration:
```bash
xcodebuild -scheme SkillKit -configuration Debug build
```

### 3. Open in Xcode
To open the workspace and run it locally on your Mac:
```bash
open SkillKit.xcodeproj
```

---

## Architecture

- **State Management**: Built with modern SwiftUI `@Observable` models and views for state tracking.
- **Persistence**: Employs **SwiftData** to cache, index, and organize scanned markdown skills, custom collections, and remote connection settings.
- **Security Scope Bookmarks**: Integrates `SandboxBookmarkManager` to securely retain user permission grants for custom folders outside the App Sandbox.
- **Agent Interactivity**: Spawns one-shot CLI commands asynchronously (e.g., `claude --print` and `codex exec`) using `Process` to get agent-assisted code adjustments.

---

## License

Distributed under the MIT License. See [LICENSE](LICENSE) for details.
