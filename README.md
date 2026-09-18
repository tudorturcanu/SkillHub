# SkillKit 🛠️

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![macOS 15.0+](https://img.shields.io/badge/macOS-15.0%2B-swift.svg)](https://developer.apple.com/macos/)
[![Swift 6](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
[![Build Status](https://img.shields.io/badge/Build-Passing-brightgreen.svg)](#build--setup-instructions)

**SkillKit** is the native macOS mission control for AI coding-agent skills, rules, system prompts, and custom instructions.

Instead of letting your agent instructions stay scattered across Claude Code, Codex, Cursor, Windsurf, Copilot, Amp, OpenCode, Hermes, and custom developer directories, **SkillKit** gathers them into a unified, lightning-fast native interface. Search, edit, security-audit, group, and reuse your agent skills from a single source of truth.

---

## 🌟 Key Features

- **Unified Developer Dashboard**: View aggregated metrics (total skills, active rules, agents, and connected remote servers) alongside a real-time activity stream.
- **Native SwiftUI Editor & Live Preview**: High-performance syntax-highlighted Markdown editor with autosave indicators and a live side-by-side HTML/Markdown preview parsing frontmatter metadata.
- **Safe Editing**: Autosave flushes when you switch items or quit, so an edit is never lost to a stray click. If an agent rewrites a file you have open, SkillKit says so and offers Reload or Keep Mine rather than overwriting either side. Deletes move to the Trash.
- **Safe Renaming**: Rename skills and rules in place while keeping frontmatter, headings, and linked agent installations synchronized.
- **Static Security Scanner**: Clean-room offline static analysis engine that checks skill instructions for prompt injections, hardcoded API keys (OpenAI, Anthropic, GitHub, AWS), SSH private key leakage, zero-width unicode tricks, and destructive shell execution. Findings carry a file and line you can jump to, and any rule can be ignored per skill.
- **Automated Skill Linter**: Automated rule checker and quick-fix provider for missing metadata, frontmatter names/descriptions, trailing whitespace, and unicode formatting. Every fix is previewed as a diff before it is written, and Markdown hard breaks and fenced code are left alone.
- **Multi-Platform Probing**: Automatically detects and scans project-local config folders, global config directories, and CLI/Desktop plugins. Rescans are incremental, so editing a skill does not re-walk the whole library.
- **Interactive Agent Chat**: Refine or refactor your instructions by chatting directly with your active local agent (e.g., Claude Code, Codex) from within the app. Replies stream as they arrive, follow-up messages keep the conversation's context, and transcripts survive closing the panel.
- **Finds Your CLI Anywhere**: Agent binaries are resolved through your login shell, so installs managed by fnm, mise, volta, bun or pnpm are picked up. You can also point SkillKit at a binary yourself in Settings → Agents.
- **Visual Diff Review**: Inspect, accept, or reject edits suggested by the agent through a native side-by-side diff review panel.
- **SSH Remote VM Syncing**: Sync and manage skill libraries on remote cloud VMs or servers over secure SSH connections.
- **Community Skill Registry**: Browse, discover, and download curated open-source agent skills directly into your local library.

---

## 📁 Scanned Agent Config Directories

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
| **Antigravity** | Antigravity | `.antigravity/skills` | `~/.agents/antigravity/skills` |

### Source of Truth (`sotDir`)

By default, the global source of truth directory resides at:
* Local Library: `~/Library/Application Support/SkillKit/LocalLibrary/`
* Change it under **Settings → Folders → Library root** to `~/.agents` or any custom path to share skills across terminal profiles. Changing it triggers a rescan.

Skills installed by Claude Code plugins and Claude Desktop are hidden by default because they are read-only; show them with **Settings → Folders → Include plugin-installed skills**.

### If the library index cannot be opened

The index is a cache over the Markdown on disk. If it is ever corrupt or cannot be migrated, SkillKit sets the file aside with a timestamped name, builds a fresh one, and rescans — rather than refusing to launch. Your skills and rules are untouched; favorites, collections and saved servers are reset, and the old file is kept so it can be recovered.

---

## ⌨️ Keyboard Shortcuts

| Action | Shortcut |
| :--- | :--- |
| New skill / New rule | `⌘N` / `⇧⌘N` |
| Save | `⌘S` |
| Duplicate | `⌘D` |
| Move to Trash | `⌘⌫` |
| Find in Library | `⌥⌘F` |
| Dashboard / Skills / Rules / Favorites | `⌘1` … `⌘4` |
| Editor / Preview / Playground | `⌥⌘1` … `⌥⌘3` |
| Bold / Italic / Strikethrough | `⌘B` / `⌘I` / `⇧⌘X` |
| Add or remove favorite | `⇧⌘F` |
| Show selected item in Finder | `⇧⌘O` |
| Rescan local skills | `⇧⌘R` |

---

## 🛠️ Build & Setup Instructions

SkillKit supports both **XcodeGen** and standard **Swift Package Manager (SPM)**.

### Prerequisites

- **macOS 15.0** or later
- **Xcode 16.0+** with Command Line Tools
- **XcodeGen** (`brew install xcodegen`)

### 1. Generate Xcode Project

```bash
xcodegen generate
```

### 2. Build via CLI

To build the app in Debug configuration:

```bash
xcodebuild -scheme SkillKit -configuration Debug build
```

### 3. Open in Xcode

```bash
open SkillKit.xcodeproj
```

---

## 🏗️ Architecture

- **State Management**: Modern SwiftUI `@Observable` models (`AppState`, `SkillScanner`) providing reactive UI state propagation.
- **Persistence**: Powered by **SwiftData** to cache, index, and organize scanned markdown skills, custom collections, and remote connection settings.
- **Security & Analysis**: `SecurityScanner` and `SkillLinter` execute offline static pattern evaluation to score skill safety (0–100 risk score) and generate actionable lint fixes.
- **Sandbox Security**: Uses `SandboxBookmarkManager` to securely persist user authorization bookmarks for directories outside the macOS App Sandbox.

---

## 🤝 Contributing

Contributions are welcome! Please read [CONTRIBUTING.md](CONTRIBUTING.md) for details on code style, testing requirements, and submitting pull requests.

---

## 🔒 Security

For security vulnerabilities and responsible disclosure guidelines, please see [SECURITY.md](SECURITY.md).

---

## 📄 License

Distributed under the MIT License. See [LICENSE](LICENSE) for details.
