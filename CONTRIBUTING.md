# Contributing to Careless Whisper

Thanks for your interest in contributing! Here's how to get started.

## Building

```bash
# Debug build
swift build

# Release build
swift build -c release

# Run tests
swift test

# Run a single test
swift test --filter CarelessWhisperTests.AudioBufferTests/testAppendAndFlush
```

## Creating an App Bundle

```bash
# Debug
./scripts/bundle.sh

# Release
./scripts/bundle.sh --release

# Release with explicit version
./scripts/bundle.sh --release --version 1.0.0
```

## Code Conventions

- **Concurrency:** `@MainActor` on all UI and state classes. `async/await` throughout.
- **Logging:** Use `os.Logger` with subsystem `"com.carelesswhisper"` and a per-module category. Use privacy markers on user-content fields.
- **Error handling:** Custom error enums conforming to `LocalizedError`, one per module.
- **UI pattern:** AppKit shell (`NSApplication`, `NSStatusItem`, `NSPanel`) with SwiftUI via `NSHostingView` for settings and overlay content.
- **Persistence:** `@AppStorage` (UserDefaults) for user settings.

## Pull Requests

1. Fork the repo and create a branch from `main`
2. Make your changes — keep PRs focused on a single concern
3. Ensure `swift build` and `swift test` pass
4. Open a PR with a clear description of what changed and why

## Reporting Issues

Use the [issue tracker](https://github.com/Tesseric/careless-whisper/issues/new/choose) to report bugs or request features.
