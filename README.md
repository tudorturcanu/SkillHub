# SkillKit 🛠️

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![macOS 15.0+](https://img.shields.io/badge/macOS-15.0%2B-swift.svg)](https://developer.apple.com/macos/)
[![Swift 6](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
[![Build Status](https://img.shields.io/badge/Build-Passing-brightgreen.svg)](#build--setup-instructions)

> The app is called **SkillKit**. This repository is named SkillHub; they are the same project.

**SkillKit** is the native macOS mission control for AI coding-agent skills, rules, system prompts, and custom instructions.

Instead of letting your agent instructions stay scattered across Claude Code, Codex, Cursor, Windsurf, Copilot, Amp, OpenCode, Hermes, and custom developer directories, **SkillKit** gathers them into a unified, lightning-fast native interface. Search, edit, security-audit, group, and reuse your agent skills from a single source of truth.

<img src="docs/skillkit.png" width="900" alt="SkillKit showing a library of skills and rules for Claude Code, Cursor, Windsurf and Codex, with one skill open in the Markdown editor">

---

## 🌟 Key Features

- **Unified Developer Dashboard**: View aggregated metrics (total skills, active rules, agents, and connected remote servers) alongside a real-time activity stream.
- **Native SwiftUI Editor & Live Preview**: High-performance syntax-highlighted Markdown editor with autosave indicators and a live side-by-side HTML/Markdown preview parsing frontmatter metadata. Links in the preview and in agent replies only open in a browser or mail client — never another app — since skills can come from the community registry.
- **Document Outline**: The toolbar's outline menu lists every heading in the open skill (skipping frontmatter and fenced code) and jumps straight to it — in the editor, or in the rendered preview when Preview is showing — so long rule files are easy to move around in.
- **Quick Actions**: Right-click any item to favorite it, copy its name, body, full file or path, reveal it in Finder, open it in your default Markdown editor (⌥⌘O), or open its folder in Terminal. ⌥⇧⌘C copies the selected item's path.
- **Structured Search**: Words match in any order, so `pdf merge` finds an item that mentions both. Use `"quotes"` for an exact phrase, `-word` to exclude, `tool:cursor` to narrow by agent, and `is:` with `skill`, `rule`, `favorite`, `project`, `global`, `local`, `remote`, `editable` or `readonly` — for example `review -draft is:rule tool:claude`.
- **Smart Collections**: Save a query such as `tool:codex is:project` in the sidebar with a name and search-field scope. Matching skills and rules update automatically as the library changes. Choose **New Smart Collection**, or right-click an existing one to edit or delete its saved search; deleting it leaves your files untouched. Queries search the entire library independently of other sidebar and quick filters.
- **Replace in Library**: Edit → Replace in Library… (⌥⌘R) finds text across every local, editable item, shows the match count per item so you can leave some out, and snapshots each file into its version history before rewriting it.
- **Compare Two Items**: Select two items and choose Compare from the right-click or Bulk Actions menu to see a line-by-line diff, handy for spotting near-duplicates across agents.
- **Possible Duplicates**: The dashboard finds items whose text is nearly the same — typically a skill copied into a second agent's folder that has since drifted — shows how alike each pair is, and opens them in Compare.
- **Context Budget**: The dashboard estimates, per agent, how many tokens your library puts into every session: each skill's name and description (skills load the rest only when used) plus the full text of every rule. Click an agent to list its items sorted Largest first.
- **Bulk Actions on Right-Click**: Right-clicking a row that is part of a multi-selection offers the bulk actions (favorite, collections, export, trash…) for the whole selection.
- **Safe Editing**: Autosave flushes when you switch items or quit, so an edit is never lost to a stray click. If an agent rewrites a file you have open, SkillKit says so and offers Reload or Keep Mine rather than overwriting either side. Deletes move to the Trash.
- **Safe Renaming**: Rename skills and rules in place while keeping frontmatter, headings, and linked agent installations synchronized.
- **Static Security Scanner**: Clean-room offline static analysis engine that checks skill instructions for prompt injections, hardcoded API keys (OpenAI, Anthropic, GitHub, AWS), SSH private key leakage, zero-width unicode tricks, and destructive shell execution. Hidden instructions are caught even when an HTML comment spans several lines, and line numbers stay correct in Windows (CRLF) files. Findings carry a file and line you can jump to, and any rule can be ignored per skill.
- **Automated Skill Linter**: Automated rule checker and quick-fix provider for missing metadata, frontmatter names/descriptions, trailing whitespace, and unicode formatting. It also warns about relative links and images that point to missing files. Skills are checked against the shared SKILL.md format — a `name` of lowercase letters, digits and hyphens (at most 64 characters) that matches its folder, and a `description` of at most 1024 characters — and a quick fix rewrites a non-conforming name. Every fix is previewed as a diff before it is written, and Markdown hard breaks and fenced code are left alone.
- **Multi-Platform Probing**: Automatically detects and scans project-local config folders, global config directories, and CLI/Desktop plugins. Rescans are incremental, so editing a skill does not re-walk the whole library.
- **Interactive Agent Chat** *(direct-distribution build only)*: Refine or refactor your instructions by chatting directly with your active local agent (e.g., Claude Code, Codex) from within the app. Replies stream as they arrive, follow-up messages keep the conversation's context, and transcripts survive closing the panel.
- **Finds Your CLI Anywhere**: Agent binaries are resolved through your login shell, so installs managed by fnm, mise, volta, bun or pnpm are picked up. You can also point SkillKit at a binary yourself in Settings → Agents.
- **Visual Diff Review**: Inspect, accept, or reject edits suggested by the agent through a native side-by-side diff review panel.
- **SSH Remote VM Syncing** *(direct-distribution build only)*: Sync and manage skill libraries on remote cloud VMs or servers over secure SSH connections. A file that can't be read, or a folder `find` can't enter, is skipped rather than failing the sync, and a skill is only removed from the library once it is actually gone from the server.
- **Reviewed Skill Updates**: New Discover installs record their GitHub repository, branch, file path, and exact commit. Open **Skill Updates → Check for Updates** on an editable local skill, then review the diff before applying. Non-overlapping local edits are preserved; conflicts can be resolved manually and reviewed again. Applying requires a successful History snapshot, and refuses a stale review if the file changed. Restore the pre-update snapshot from History to roll back the file and its tracked revision. Updates currently cover `SKILL.md` only; older installations without a recorded source are shown as untracked.
- **Community Skill Registry**: Browse, discover, and download curated open-source agent skills directly into your local library.

### App Store edition

The App Store build focuses on managing local skills and rules. It omits Interactive Agent Chat and SSH Remote VM Syncing because macOS App Sandbox does not allow it to launch command-line tools installed outside the app. The direct-distribution build retains those features.

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

### 4. Run the tests

The library and its tests also build as a Swift package, so no project generation is needed:

```bash
swift test
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
