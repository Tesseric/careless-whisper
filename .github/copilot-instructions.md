# Copilot Instructions

## Build & Test

```bash
# Build
swift build

# Build release
swift build -c release

# Bundle as macOS .app
./scripts/bundle.sh            # debug
./scripts/bundle.sh --release  # release

# Run all tests
swift test

# Run a single test
swift test --filter CarelessWhisperTests.AudioBufferTests/testAppendAndFlush
```

## Architecture

Careless Whisper is a macOS menu bar app that records speech via a push-to-talk hotkey, transcribes it locally using Whisper, and injects the text into the frontmost application.

**Lifecycle:** `CarelessWhisperApp.main()` → `NSApplication` with `.accessory` policy (no dock icon) → `AppDelegate` → creates `AppState` + `StatusBarController`.

**AppState** is the central orchestrator (`@MainActor`, `ObservableObject`). It owns all services and manages the recording state machine: `idle → recording → transcribing → idle`. It uses a chunk queue (`pendingChunks` + `processNextChunk()`) to serialize live transcription during recording.

### Module Responsibilities

- **Audio/** – `AudioCaptureService` captures mic input via `AVAudioEngine`, resamples to 16kHz mono Float32 (Whisper's required format), and performs voice activity detection (600ms silence → chunk boundary, chunks ≥300ms, max 10s). `AudioBuffer` is a thread-safe circular buffer using `os_unfair_lock`.
- **Transcription/** – `WhisperService` wraps SwiftWhisper. Uses `Task.detached` to avoid `@MainActor` deadlock since SwiftWhisper resumes on `DispatchQueue.main`. `ModelManager` downloads GGML models + optional CoreML encoders from HuggingFace to `~/Library/Application Support/CarelessWhisper/Models`.
- **TextInjection/** – Strategy pattern via `TextInjectorCoordinator`. Detects the target app at recording start. Kitty terminal gets IPC via `kitten @ send-text`; everything else falls back to clipboard paste with Cmd+V simulation via `CGEvent`.
- **HotKey/** – `HotKeyManager` registers global hotkeys (default: Option+`). Key down starts recording, key up stops and transcribes.
- **Permissions/** – Checks/requests microphone (`AVCaptureDevice`) and accessibility (`AXIsProcessTrusted`).
- **UI/** – `StatusBarController` (NSMenu-based menu bar), `RecordingOverlayController` (floating HUD during recording), `SettingsWindowController`/`SettingsView` (SwiftUI settings).

## Conventions

- **Concurrency:** `@MainActor` on all UI/state classes. `async/await` throughout. `Task.detached` only where `@MainActor` isolation would cause deadlocks (WhisperService). `AudioBuffer` uses `os_unfair_lock` (not Swift concurrency) for real-time audio thread safety.
- **Error handling:** Custom error enums with `LocalizedError` conformance per module (`AudioCaptureError`, `WhisperServiceError`, `ModelManagerError`, `KittyIPCError`). Text injection degrades gracefully: Kitty IPC failure → clipboard fallback.
- **Logging:** `os.Logger` with subsystem `"com.carelesswhisper"` and privacy markers.
- **Persistence:** `@AppStorage` (UserDefaults) for settings like selected model, input device, completion sound, auto-enter.
- **Platform:** macOS 14+ only. Uses AppKit (`NSApplication`, `NSStatusItem`, `NSPanel`) with SwiftUI for settings views.
