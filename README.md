# SkillKit

SkillKit is mission control for AI coding-agent skills on macOS.

It finds the instructions scattered across Claude Code, Codex, Cursor, Amp, Windsurf, and other agent folders, then gives them one native place to be searched, edited, grouped, and reused.

## What Makes It Different

- Native SwiftUI app, not a web dashboard
- Built for agent skills, rules, and prompts rather than generic notes
- Reads real filesystem locations instead of forcing a new storage format
- Keeps user-created collections separate from files on disk
- Supports shared skills through a global `~/.agents` source of truth
- Includes a local editor and diff review flow for agent-assisted edits

## Requirements

- macOS 15 or later
- Xcode with command-line tools
- XcodeGen (`brew install xcodegen`)

## Build

```bash
xcodegen generate
xcodebuild -scheme SkillKit -configuration Debug build
```

To work in Xcode:

```bash
open SkillKit.xcodeproj
```

## License

MIT. See [LICENSE](LICENSE).
