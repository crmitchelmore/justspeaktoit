# Contributing to Just Speak to It

Thank you for your interest in contributing! This document provides guidelines and instructions for contributing.

## Quick Start

```bash
# Clone the repository
git clone https://github.com/chrismitchelmore/just-speak-to-it.git
cd just-speak-to-it

# Build and run (macOS)
make run

# Run tests
make test
```

## Development Setup

### Prerequisites

- **macOS 14+** with Xcode 15+ (includes Swift 5.9)
- **iOS 17+** target for iOS development
- [Tuist](https://tuist.io) for Xcode project generation (optional)

### Project Structure

```
Sources/
├── SpeakCore/      # Cross-platform shared code
├── SpeakApp/       # macOS application
└── SpeakiOS/       # iOS library
SpeakiOSApp/        # iOS app entry point
Tests/              # Test suite
```

### Building

| Command | Description |
|---------|-------------|
| `make run` | Build and launch macOS app |
| `make build` | Compile in debug mode |
| `make test` | Run test suite |
| `make clean` | Remove build artifacts |

For iOS development:
```bash
tuist generate
open "Just Speak to It.xcworkspace"
```

## How to Contribute

### Reporting Bugs

1. Check [existing issues](https://github.com/chrismitchelmore/just-speak-to-it/issues) first
2. Use the bug report template
3. Include: macOS/iOS version, steps to reproduce, expected vs actual behavior

### Suggesting Features

1. Open an issue using the feature request template
2. Describe the use case and why it would benefit users

### Submitting Code

1. **Fork** the repository
2. **Create a branch** from `main`:
   ```bash
   git checkout -b feat/your-feature-name
   ```
3. **Make your changes** following our coding standards
4. **Test** your changes:
   ```bash
   make test
   ```
5. **Commit** using [Conventional Commits](https://www.conventionalcommits.org/):
   ```bash
   git commit -m "feat: add voice activity detection"
   git commit -m "fix: resolve audio session conflict on iOS"
   ```
6. **Push** and open a Pull Request

### Commit Message Format

We use Conventional Commits:

- `feat:` New features
- `fix:` Bug fixes
- `docs:` Documentation changes
- `chore:` Maintenance tasks
- `refactor:` Code refactoring
- `test:` Test additions/changes

## Coding Standards

### Swift Style

- **4-space indentation** (configured in `.swiftformat`)
- **120 character line limit** (soft), 160 (hard)
- Use `explicit_self` where configured
- Follow SwiftUI conventions for view code

### Linting

```bash
# Run SwiftLint
swift package plugin --allow-writing-to-package-directory swiftlint --strict

# Run SwiftFormat
swift package plugin --allow-writing-to-package-directory swiftformat
```

### Code Organization

- **Cross-platform code** → `SpeakCore`
- **macOS-specific** → `SpeakApp`
- **iOS-specific** → `SpeakiOS` (use `#if os(iOS)` guards)
- Keep types `internal` unless cross-module access is needed

## Pull Request Guidelines

- Keep PRs focused on a single concern
- Include tests for new functionality
- Update documentation if needed
- Ensure CI passes before requesting review
- Reference related issues in the PR description

## Getting Help

- Open a [Discussion](https://github.com/chrismitchelmore/just-speak-to-it/discussions) for questions
- Check existing issues and PRs
- Review the [documentation](./Docs/)

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](./LICENSE).
