# Contributing to SkillKit

Thank you for your interest in contributing to SkillKit! SkillKit aims to be the gold standard native macOS application for managing AI coding-agent skills, rules, and system prompts.

## Development Guidelines

1. **Architecture & Swift Standards**
   - Built with modern SwiftUI `@Observable` and SwiftData (`SchemaV1`).
   - Keep views modular, performant, and responsive on macOS.
   - Follow standard Swift style guidelines and explicit type safety.

2. **Codebase Project Setup**
   - Project configuration is managed via `project.yml` using `XcodeGen`.
   - Run `xcodegen generate` after modifying target or project structures.
   - Ensure all new features include unit tests in `SkillKitTests/`.

3. **Submitting Pull Requests**
   - Fork the repository and create your feature branch (`git checkout -b feature/amazing-feature`).
   - Ensure your code builds cleanly without warnings (`xcodebuild -scheme SkillKit build`).
   - Write unit tests for your changes.
   - Submit a clear Pull Request detailing what changed and why.

## Code of Conduct

We are committed to providing a welcoming and inclusive community. Please be respectful and constructive in all interactions.
